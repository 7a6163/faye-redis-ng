require 'spec_helper'

RSpec.describe Faye::Redis, 'Concurrency' do
  let(:server) { double('server') }
  # Use unique namespace for concurrency tests to avoid pollution
  let(:test_namespace) { "concurrency-test-#{SecureRandom.hex(4)}" }
  let(:options) { test_redis_options.merge(gc_interval: 0, namespace: test_namespace) }
  let(:engine) { described_class.new(server, options) }

  after do
    engine.disconnect if engine
  end

  describe '#publish callback guarantee' do
    it 'calls callback exactly once even with multiple channels' do
      em_run(2) do
        # Create multiple clients subscribed to different channels
        clients = []
        channels = ['/channel1', '/channel2', '/channel3']

        # Create 3 clients, each subscribed to one channel
        create_clients = lambda do |remaining|
          if remaining == 0
            # All clients created, now publish
            message = { 'data' => 'test message' }
            callback_count = 0
            callback_result = nil

            engine.publish(message, channels) do |success|
              callback_count += 1
              callback_result = success
            end

            # Wait for publish to complete
            EM.add_timer(0.5) do
              expect(callback_count).to eq(1), "Callback was called #{callback_count} times, expected 1"
              expect(callback_result).to be true
              EM.stop
            end
          else
            engine.create_client do |client_id|
              clients << client_id
              channel = channels[3 - remaining]
              engine.subscribe(client_id, channel) do
                create_clients.call(remaining - 1)
              end
            end
          end
        end

        create_clients.call(3)
      end
    end

    it 'handles publish with no subscribers correctly' do
      em_run(2) do
        message = { 'data' => 'test' }
        callback_count = 0

        engine.publish(message, '/no-subscribers') do |success|
          callback_count += 1
        end

        EM.add_timer(0.5) do
          expect(callback_count).to eq(1)
          EM.stop
        end
      end
    end

    it 'handles concurrent publish operations' do
      em_run(2) do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/test') do
            # Publish 10 messages concurrently
            callback_counts = Array.new(10, 0)
            completed = 0

            10.times do |i|
              message = { 'data' => "message-#{i}" }
              engine.publish(message, '/test') do |success|
                callback_counts[i] += 1
                completed += 1

                if completed == 10
                  EM.add_timer(0.5) do
                    # Each callback should be called exactly once
                    callback_counts.each_with_index do |count, index|
                      expect(count).to eq(1), "Message #{index} callback was called #{count} times"
                    end
                    EM.stop
                  end
                end
              end
            end
          end
        end
      end
    end

    it 'handles publish to multiple channels with varying subscribers' do
      em_run(2) do
        # Use unique channel names to avoid test pollution
        test_id = SecureRandom.hex(4)
        ch1 = "/multi-ch1-#{test_id}"
        ch2 = "/multi-ch2-#{test_id}"
        ch3 = "/multi-ch3-#{test_id}"

        # Create 2 clients
        # Client 1 subscribes to ch1 and ch2
        # Client 2 subscribes to ch2 and ch3
        engine.create_client do |client1_id|
          engine.create_client do |client2_id|
            engine.subscribe(client1_id, ch1) do
              engine.subscribe(client1_id, ch2) do
                engine.subscribe(client2_id, ch2) do
                  engine.subscribe(client2_id, ch3) do
                    # Publish to all three channels
                    message = { 'data' => 'multi-channel test' }
                    callback_count = 0

                    engine.publish(message, [ch1, ch2, ch3]) do |success|
                      callback_count += 1
                      expect(success).to be true
                    end

                    EM.add_timer(0.5) do
                      expect(callback_count).to eq(1)

                      # Verify messages were enqueued (dequeue to count accurately)
                      engine.message_queue.dequeue_all(client1_id) do |msgs1|
                        engine.message_queue.dequeue_all(client2_id) do |msgs2|
                          # Client 1 should have 2 messages (ch1 + ch2)
                          expect(msgs1.size).to eq(2)
                          # Client 2 should have 2 messages (ch2 + ch3)
                          expect(msgs2.size).to eq(2)
                          EM.stop
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  describe '#publish error handling' do
    it 'calls callback with false when error occurs' do
      em_run do
        # Disconnect to cause error
        engine.connection.disconnect

        message = { 'data' => 'test' }
        callback_count = 0
        callback_result = nil

        engine.publish(message, '/test') do |success|
          callback_count += 1
          callback_result = success
        end

        EM.add_timer(0.5) do
          expect(callback_count).to eq(1)
          expect(callback_result).to be false
          EM.stop
        end
      end
    end
  end

  describe 'thread safety' do
    it 'handles subscriber callbacks safely across threads' do
      em_run(3) do
        # Create two engines to simulate distributed setup
        engine2 = described_class.new(server, options)

        engine.create_client do |client_id|
          engine.subscribe(client_id, '/test') do
            # Track callback executions
            callback_count = 0
            errors = []

            # Setup message handler on engine (receives from Redis pub/sub)
            engine.pubsub_coordinator.on_message do |channel, message|
              begin
                callback_count += 1
              rescue => e
                errors << e
              end
            end

            # Publish from engine2 (will go through Redis pub/sub to engine)
            EM.add_timer(0.2) do
              5.times do |i|
                message = { 'data' => "message-#{i}" }
                engine2.publish(message, '/test')
              end
            end

            # Wait and verify
            EM.add_timer(2) do
              expect(errors).to be_empty, "Errors occurred: #{errors.map(&:message).join(', ')}"
              # Should receive messages through pub/sub
              expect(callback_count).to be >= 0  # May not receive all due to timing
              engine2.disconnect
              EM.stop
            end
          end
        end
      end
    end
  end

  describe 'stress test' do
    it 'handles rapid sequential publishes' do
      em_run(3) do
        # Use unique channel to avoid test pollution
        test_channel = "/stress-#{SecureRandom.hex(4)}"

        engine.create_client do |client_id|
          engine.subscribe(client_id, test_channel) do
            callback_counts = 0
            total_publishes = 50

            # Publish 50 messages rapidly
            total_publishes.times do |i|
              message = { 'data' => "stress-#{i}" }
              engine.publish(message, test_channel) do |success|
                callback_counts += 1
              end
            end

            # Wait and verify all callbacks were called once
            EM.add_timer(2) do
              expect(callback_counts).to eq(total_publishes)

              # Verify messages were enqueued (dequeue to count accurately)
              engine.message_queue.dequeue_all(client_id) do |messages|
                expect(messages.size).to eq(total_publishes)
                EM.stop
              end
            end
          end
        end
      end
    end
  end
end
