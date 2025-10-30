require 'spec_helper'

RSpec.describe Faye::Redis do
  let(:server) { double('server') }
  let(:options) { test_redis_options }
  let(:engine) { described_class.new(server, options) }

  after do
    engine.disconnect if engine
  end

  describe '.create' do
    it 'creates a new engine instance' do
      engine = described_class.create(server, options)
      expect(engine).to be_a(Faye::Redis)
      engine.disconnect
    end
  end

  describe '#initialize' do
    it 'initializes all components' do
      expect(engine.connection).to be_a(Faye::Redis::Connection)
      expect(engine.client_registry).to be_a(Faye::Redis::ClientRegistry)
      expect(engine.subscription_manager).to be_a(Faye::Redis::SubscriptionManager)
      expect(engine.message_queue).to be_a(Faye::Redis::MessageQueue)
      expect(engine.pubsub_coordinator).to be_a(Faye::Redis::PubSubCoordinator)
    end

    it 'merges options with defaults' do
      expect(engine.options[:host]).to eq('localhost')
      expect(engine.options[:namespace]).to eq('test')
    end
  end

  describe '#create_client' do
    it 'creates a new client' do
      em_run do
        engine.create_client do |client_id|
          expect(client_id).not_to be_nil
          expect(client_id).to be_a(String)
          EM.stop
        end
      end
    end

    it 'generates UUID format client IDs' do
      em_run do
        engine.create_client do |client_id|
          # UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
          uuid_pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
          expect(client_id).to match(uuid_pattern)
          EM.stop
        end
      end
    end

    it 'generates unique client IDs' do
      em_run do
        client_ids = []

        engine.create_client do |client_id1|
          client_ids << client_id1

          engine.create_client do |client_id2|
            client_ids << client_id2

            engine.create_client do |client_id3|
              client_ids << client_id3

              expect(client_ids.uniq.length).to eq(3)
              EM.stop
            end
          end
        end
      end
    end

    it 'registers client in registry' do
      em_run do
        engine.create_client do |client_id|
          engine.client_registry.exists?(client_id) do |exists|
            expect(exists).to be true
            EM.stop
          end
        end
      end
    end

    it 'returns nil when client creation fails' do
      em_run do
        # Mock client_registry to fail
        allow(engine.client_registry).to receive(:create).and_yield(false)

        engine.create_client do |client_id|
          expect(client_id).to be_nil
          EM.stop
        end
      end
    end
  end

  describe '#destroy_client' do
    it 'destroys a client' do
      em_run do
        engine.create_client do |client_id|
          engine.destroy_client(client_id) do |success|
            expect(success).to be true

            engine.client_registry.exists?(client_id) do |exists|
              expect(exists).to be false
              EM.stop
            end
          end
        end
      end
    end

    it 'unsubscribes from all channels' do
      em_run do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            engine.destroy_client(client_id) do
              engine.subscription_manager.get_client_subscriptions(client_id) do |channels|
                expect(channels).to be_empty
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe '#client_exists' do
    it 'checks if client exists' do
      em_run do
        engine.create_client do |client_id|
          engine.client_exists(client_id) do |exists|
            expect(exists).to be true
            EM.stop
          end
        end
      end
    end

    it 'returns false for non-existent client' do
      em_run do
        engine.client_exists('non-existent') do |exists|
          expect(exists).to be false
          EM.stop
        end
      end
    end
  end

  describe '#ping' do
    it 'pings a client to keep it alive' do
      em_run do
        engine.create_client do |client_id|
          expect { engine.ping(client_id) }.not_to raise_error
          EM.stop
        end
      end
    end
  end

  describe '#subscribe' do
    it 'subscribes a client to a channel' do
      em_run do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do |success|
            expect(success).to be true
            EM.stop
          end
        end
      end
    end
  end

  describe '#unsubscribe' do
    it 'unsubscribes a client from a channel' do
      em_run do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            engine.unsubscribe(client_id, '/messages') do |success|
              expect(success).to be true
              EM.stop
            end
          end
        end
      end
    end
  end

  describe '#publish' do
    it 'publishes a message to a channel' do
      em_run(2) do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            message = {
              'channel' => '/messages',
              'data' => { 'text' => 'Hello' }
            }

            engine.publish(message, '/messages')

            EM.add_timer(0.5) do
              engine.message_queue.size(client_id) do |size|
                expect(size).to be > 0
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'calls callback with success status' do
      em_run(2) do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            message = {
              'channel' => '/messages',
              'data' => { 'text' => 'Hello' }
            }

            callback_called = false
            engine.publish(message, '/messages') do |success|
              callback_called = true
              expect(success).to be true
            end

            EM.add_timer(0.5) do
              expect(callback_called).to be true
              EM.stop
            end
          end
        end
      end
    end

    it 'handles publish errors in callback' do
      em_run do
        # Disconnect to cause error
        engine.connection.disconnect

        message = { 'data' => { 'text' => 'Test' } }

        engine.publish(message, '/messages') do |success|
          expect(success).to be false
          EM.stop
        end
      end
    end

    it 'handles multiple channels' do
      em_run(2) do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            engine.subscribe(client_id, '/notifications') do
              message = { 'data' => { 'text' => 'Test' } }

              engine.publish(message, ['/messages', '/notifications'])

              EM.add_timer(0.5) do
                engine.message_queue.size(client_id) do |size|
                  expect(size).to be >= 2
                  EM.stop
                end
              end
            end
          end
        end
      end
    end

    it 'works without callback (backward compatible)' do
      em_run(2) do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            message = { 'channel' => '/messages', 'data' => { 'text' => 'Test' } }

            # Should not raise error when called without callback
            expect { engine.publish(message, '/messages') }.not_to raise_error

            EM.add_timer(0.5) do
              engine.message_queue.size(client_id) do |size|
                expect(size).to be > 0
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe '#empty_queue' do
    it 'empties a client message queue' do
      em_run(2) do
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/messages') do
            message = {
              'channel' => '/messages',
              'data' => { 'text' => 'Test' }
            }

            engine.message_queue.enqueue(client_id, message) do
              messages = engine.empty_queue(client_id)

              EM.add_timer(0.1) do
                engine.message_queue.size(client_id) do |size|
                  expect(size).to eq(0)
                  EM.stop
                end
              end
            end
          end
        end
      end
    end
  end

  describe '#disconnect' do
    it 'disconnects all components' do
      engine.disconnect
      expect { engine.connection.ping }.to raise_error(ConnectionPool::PoolShuttingDownError)
    end
  end

  describe 'error logging' do
    it 'logs errors through logger' do
      expect(engine.instance_variable_get(:@logger)).to receive(:error).with(/test error/)
      engine.send(:log_error, 'test error')
    end
  end

  describe 'private methods' do
    it 'generates client IDs using generate_client_id' do
      client_id = engine.send(:generate_client_id)
      uuid_pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      expect(client_id).to match(uuid_pattern)
    end

    it 'sets up message routing in setup_message_routing' do
      expect(engine.pubsub_coordinator.instance_variable_get(:@subscribers)).not_to be_empty
    end
  end

  describe '#publish with exceptions' do
    it 'handles exceptions during publish' do
      em_run do
        # Mock to raise exception
        allow(engine.subscription_manager).to receive(:get_subscribers).and_raise(StandardError.new('test error'))

        message = { 'data' => 'test' }
        engine.publish(message, '/test') do |success|
          expect(success).to be false
          EM.stop
        end
      end
    end
  end

  describe 'automatic garbage collection' do
    it 'starts GC timer by default with 60 second interval' do
      em_run do
        new_engine = described_class.new(server, options)
        expect(new_engine.instance_variable_get(:@gc_timer)).not_to be_nil
        new_engine.disconnect
        EM.stop
      end
    end

    it 'does not start GC timer when gc_interval is 0' do
      em_run do
        new_engine = described_class.new(server, options.merge(gc_interval: 0))
        expect(new_engine.instance_variable_get(:@gc_timer)).to be_nil
        new_engine.disconnect
        EM.stop
      end
    end

    it 'does not start GC timer when gc_interval is false' do
      em_run do
        new_engine = described_class.new(server, options.merge(gc_interval: false))
        expect(new_engine.instance_variable_get(:@gc_timer)).to be_nil
        new_engine.disconnect
        EM.stop
      end
    end

    it 'runs cleanup_expired periodically' do
      em_run do
        # Use a short interval for testing (0.5 seconds)
        new_engine = described_class.new(server, options.merge(gc_interval: 0.5))

        # Track cleanup calls
        cleanup_count = 0
        allow(new_engine).to receive(:cleanup_expired).and_wrap_original do |method, &block|
          cleanup_count += 1
          method.call(&block)
        end

        # Wait for at least 2 GC cycles
        EM.add_timer(1.2) do
          expect(cleanup_count).to be >= 2
          new_engine.disconnect
          EM.stop
        end
      end
    end

    it 'stops GC timer on disconnect' do
      em_run do
        new_engine = described_class.new(server, options)
        timer = new_engine.instance_variable_get(:@gc_timer)
        expect(timer).not_to be_nil

        new_engine.disconnect
        expect(new_engine.instance_variable_get(:@gc_timer)).to be_nil
        EM.stop
      end
    end
  end

  describe '#cleanup_expired' do
    it 'cleans up expired clients and orphaned subscriptions' do
      em_run do
        namespace = options[:namespace] || 'faye'

        # Create a client and subscription
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/test/channel') do
            subscriptions_key = "#{namespace}:subscriptions:#{client_id}"
            subscription_key = "#{namespace}:subscription:#{client_id}:/test/channel"
            channel_key = "#{namespace}:channels:/test/channel"

            # Manually remove ONLY the client (not subscriptions) to simulate crash
            engine.connection.with_redis do |redis|
              redis.del("#{namespace}:clients:#{client_id}")
              redis.srem("#{namespace}:clients:index", client_id)
            end

            # Verify orphaned subscription keys still exist
            engine.connection.with_redis do |redis|
              expect(redis.exists?(subscriptions_key)).to be_truthy
              expect(redis.exists?(subscription_key)).to be_truthy
              expect(redis.sismember(channel_key, client_id)).to be_truthy
            end

            # Run cleanup
            engine.cleanup_expired do |count|
              # Verify orphaned keys are removed
              engine.connection.with_redis do |redis|
                expect(redis.exists?(subscriptions_key)).to be_falsey
                expect(redis.exists?(subscription_key)).to be_falsey
                expect(redis.sismember(channel_key, client_id)).to be_falsey
              end

              EM.stop
            end
          end
        end
      end
    end

    it 'handles cleanup with no expired clients' do
      em_run do
        engine.cleanup_expired do |count|
          expect(count).to eq(0)
          EM.stop
        end
      end
    end

    it 'cleans up message queues for orphaned clients' do
      em_run do
        namespace = options[:namespace] || 'faye'

        # Create a client
        engine.create_client do |client_id|
          engine.subscribe(client_id, '/test') do
            # Enqueue a message
            message = { 'channel' => '/test', 'data' => 'test data' }
            engine.message_queue.enqueue(client_id, message) do
              messages_key = "#{namespace}:messages:#{client_id}"

              # Verify message queue exists
              engine.connection.with_redis do |redis|
                expect(redis.exists?(messages_key)).to be_truthy
              end

              # Manually remove ONLY the client (not messages) to simulate crash
              engine.connection.with_redis do |redis|
                redis.del("#{namespace}:clients:#{client_id}")
                redis.srem("#{namespace}:clients:index", client_id)
              end

              # Message queue should still exist (orphaned)
              engine.connection.with_redis do |redis|
                expect(redis.exists?(messages_key)).to be_truthy
              end

              # Run cleanup
              engine.cleanup_expired do
                # Verify message queue is removed
                engine.connection.with_redis do |redis|
                  expect(redis.exists?(messages_key)).to be_falsey
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
