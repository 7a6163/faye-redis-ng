require 'spec_helper'

RSpec.describe Faye::Redis::PubSubCoordinator do
  let(:connection) { Faye::Redis::Connection.new(test_redis_options) }
  let(:options) { test_redis_options }
  let(:coordinator) { described_class.new(connection, options) }

  after do
    coordinator.disconnect
    connection.disconnect
  end

  describe '#initialize' do
    it 'initializes without setting up subscriber immediately' do
      expect(coordinator.instance_variable_get(:@subscriber_thread)).to be_nil
    end

    it 'sets default options' do
      expect(coordinator.connection).to eq(connection)
      expect(coordinator.options).to eq(options)
    end
  end

  describe '#publish' do
    it 'publishes a message to a channel' do
      em_run do
        message = { 'data' => 'test' }

        coordinator.publish('/test', message) do |success|
          expect(success).to be true
          EM.stop
        end
      end
    end

    it 'sets up subscriber on first publish' do
      em_run do
        message = { 'data' => 'test' }

        coordinator.publish('/test', message) do
          expect(coordinator.instance_variable_get(:@subscriber_thread)).not_to be_nil
          EM.stop
        end
      end
    end

    it 'handles publish errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        message = { 'data' => 'test' }
        coordinator.publish('/test', message) do |success|
          expect(success).to be false
          EM.stop
        end
      end
    end

    it 'converts message to JSON' do
      em_run do
        message = { 'data' => { 'nested' => 'value' } }

        expect(message).to receive(:to_json).and_call_original
        coordinator.publish('/test', message) do
          EM.stop
        end
      end
    end
  end

  describe '#on_message' do
    it 'registers message handlers' do
      handler = proc { |channel, message| }
      coordinator.on_message(&handler)

      expect(coordinator.instance_variable_get(:@subscribers)).to include(handler)
    end

    it 'calls handlers when messages are received' do
      # Use two separate coordinators to test pub/sub between instances
      coordinator2 = described_class.new(connection, options)

      em_run(3) do
        received_channel = nil
        received_message = nil

        # Subscribe on first coordinator
        coordinator.on_message do |channel, message|
          received_channel = channel
          received_message = message
        end

        # Ensure subscriber is set up
        coordinator.publish('/warmup', { 'data' => 'warmup' }) do
          # Wait for subscriber to be ready
          EM.add_timer(0.5) do
            # Publish from second coordinator
            message = { 'data' => 'test' }
            coordinator2.publish('/test', message) do
              # Wait for pub/sub to propagate
              EM.add_timer(1) do
                expect(received_channel).to eq('/test')
                expect(received_message).to eq(message)
                coordinator2.disconnect
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe '#disconnect' do
    it 'stops the subscriber thread' do
      em_run do
        coordinator.publish('/test', { 'data' => 'test' }) do
          thread = coordinator.instance_variable_get(:@subscriber_thread)

          coordinator.disconnect

          sleep 0.1
          expect(coordinator.instance_variable_get(:@subscriber_thread)).to be_nil
          EM.stop
        end
      end
    end

    it 'clears subscribers' do
      coordinator.on_message { |channel, message| }
      coordinator.disconnect

      expect(coordinator.instance_variable_get(:@subscribers)).to be_empty
    end

    it 'clears subscribed channels' do
      coordinator.instance_variable_get(:@subscribed_channels).add('/test')
      coordinator.disconnect

      expect(coordinator.instance_variable_get(:@subscribed_channels)).to be_empty
    end

    it 'sets stop flag' do
      coordinator.disconnect
      expect(coordinator.instance_variable_get(:@stop_subscriber)).to be true
    end
  end

  describe 'reconnect behavior' do
    it 'attempts to reconnect on connection failure' do
      em_run(3) do
        # Set low reconnect attempts for testing
        options = test_redis_options.merge(
          pubsub_max_reconnect_attempts: 2,
          pubsub_reconnect_delay: 0.1
        )
        coordinator = described_class.new(connection, options)

        # Track reconnect attempts by monitoring error logs
        error_count = 0
        allow(coordinator).to receive(:log_error) do |message|
          error_count += 1 if message.include?('attempt')
        end

        # Force an error by using invalid connection
        allow(connection).to receive(:create_pubsub_connection).and_raise(Redis::ConnectionError.new('test error'))

        # Trigger subscriber setup
        coordinator.publish('/test', { 'data' => 'test' })

        EM.add_timer(1) do
          coordinator.disconnect
          expect(error_count).to be > 0
          EM.stop
        end
      end
    end

    it 'stops after max reconnect attempts' do
      em_run(3) do
        options = test_redis_options.merge(
          pubsub_max_reconnect_attempts: 2,
          pubsub_reconnect_delay: 0.1
        )
        coordinator = described_class.new(connection, options)

        # Force errors
        allow(connection).to receive(:create_pubsub_connection).and_raise(Redis::ConnectionError.new('test error'))

        max_reached = false
        allow(coordinator).to receive(:log_error) do |message|
          max_reached = true if message.include?('Max reconnect attempts')
        end

        coordinator.publish('/test', { 'data' => 'test' })

        EM.add_timer(1.5) do
          coordinator.disconnect
          expect(max_reached).to be true
          EM.stop
        end
      end
    end

    it 'resets reconnect counter on successful connection' do
      em_run(2) do
        options = test_redis_options.merge(
          pubsub_reconnect_delay: 0.1
        )
        coordinator = described_class.new(connection, options)

        # Publish successfully
        coordinator.publish('/test', { 'data' => 'test' }) do
          EM.add_timer(0.5) do
            # Should have reset to 0 on successful subscription
            expect(coordinator.instance_variable_get(:@reconnect_attempts)).to eq(0)
            coordinator.disconnect
            EM.stop
          end
        end
      end
    end
  end

  describe 'message handling' do
    it 'parses JSON messages correctly' do
      # Use two separate coordinators to test pub/sub
      coordinator2 = described_class.new(connection, options)

      em_run(3) do
        received_message = nil

        # Subscribe on first coordinator
        coordinator.on_message do |channel, message|
          received_message = message
        end

        # Ensure subscriber is set up
        coordinator.publish('/warmup', { 'data' => 'warmup' }) do
          # Wait for subscriber to be ready
          EM.add_timer(0.5) do
            # Publish from second coordinator
            message = { 'data' => { 'key' => 'value' }, 'channel' => '/test' }
            coordinator2.publish('/test', message) do
              EM.add_timer(1) do
                expect(received_message).to eq(message)
                coordinator2.disconnect
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'handles JSON parse errors gracefully' do
      em_run do
        coordinator.on_message { |channel, message| }

        # This should not raise an error even if JSON is invalid
        coordinator.send(:handle_message, 'test:publish:/test', 'invalid json')

        EM.add_timer(0.1) do
          EM.stop
        end
      end
    end

    it 'extracts channel from redis channel correctly' do
      redis_channel = 'test:publish:/messages/chat'
      channel = coordinator.send(:extract_channel, redis_channel)
      expect(channel).to eq('/messages/chat')
    end
  end

  describe 'namespace handling' do
    it 'uses namespace from options' do
      options = test_redis_options.merge(namespace: 'custom')
      coordinator = described_class.new(connection, options)

      channel = coordinator.send(:pubsub_channel, '/test')
      expect(channel).to eq('custom:publish:/test')
    end

    it 'uses default namespace' do
      channel = coordinator.send(:pubsub_channel, '/test')
      expect(channel).to start_with('test:publish:') # test is our test namespace
    end
  end
end
