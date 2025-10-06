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
end
