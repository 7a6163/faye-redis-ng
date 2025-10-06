require 'spec_helper'

RSpec.describe Faye::Redis::SubscriptionManager do
  let(:connection) { Faye::Redis::Connection.new(test_redis_options) }
  let(:manager) { described_class.new(connection, test_redis_options) }

  after do
    connection.disconnect
  end

  describe '#subscribe' do
    it 'subscribes a client to a channel' do
      em_run do
        manager.subscribe('client-1', '/messages') do |success|
          expect(success).to be true
          EM.stop
        end
      end
    end

    it 'stores subscription data' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.get_client_subscriptions('client-1') do |channels|
            expect(channels).to include('/messages')
            EM.stop
          end
        end
      end
    end

    it 'adds client to channel subscribers' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.get_subscribers('/messages') do |clients|
            expect(clients).to include('client-1')
            EM.stop
          end
        end
      end
    end
  end

  describe '#unsubscribe' do
    it 'unsubscribes a client from a channel' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.unsubscribe('client-1', '/messages') do |success|
            expect(success).to be true

            manager.get_client_subscriptions('client-1') do |channels|
              expect(channels).not_to include('/messages')
              EM.stop
            end
          end
        end
      end
    end

    it 'removes client from channel subscribers' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.unsubscribe('client-1', '/messages') do
            manager.get_subscribers('/messages') do |clients|
              expect(clients).not_to include('client-1')
              EM.stop
            end
          end
        end
      end
    end
  end

  describe '#unsubscribe_all' do
    it 'unsubscribes client from all channels' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.subscribe('client-1', '/notifications') do
            manager.unsubscribe_all('client-1') do |success|
              expect(success).to be true

              manager.get_client_subscriptions('client-1') do |channels|
                expect(channels).to be_empty
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe '#get_client_subscriptions' do
    it 'returns all channels a client is subscribed to' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.subscribe('client-1', '/notifications') do
            manager.get_client_subscriptions('client-1') do |channels|
              expect(channels).to contain_exactly('/messages', '/notifications')
              EM.stop
            end
          end
        end
      end
    end

    it 'returns empty array for client with no subscriptions' do
      em_run do
        manager.get_client_subscriptions('client-1') do |channels|
          expect(channels).to eq([])
          EM.stop
        end
      end
    end
  end

  describe '#get_subscribers' do
    it 'returns all clients subscribed to a channel' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.subscribe('client-2', '/messages') do
            manager.get_subscribers('/messages') do |clients|
              expect(clients).to contain_exactly('client-1', 'client-2')
              EM.stop
            end
          end
        end
      end
    end

    it 'returns empty array for channel with no subscribers' do
      em_run do
        manager.get_subscribers('/messages') do |clients|
          expect(clients).to eq([])
          EM.stop
        end
      end
    end
  end

  describe 'wildcard subscriptions' do
    describe '#channel_matches_pattern?' do
      it 'matches single-level wildcard' do
        expect(manager.channel_matches_pattern?('/chat/room1', '/chat/*')).to be true
        expect(manager.channel_matches_pattern?('/chat/room2', '/chat/*')).to be true
        expect(manager.channel_matches_pattern?('/chat/room1/private', '/chat/*')).to be false
      end

      it 'matches multi-level wildcard' do
        expect(manager.channel_matches_pattern?('/chat/room1', '/chat/**')).to be true
        expect(manager.channel_matches_pattern?('/chat/room1/private', '/chat/**')).to be true
        expect(manager.channel_matches_pattern?('/other/channel', '/chat/**')).to be false
      end

      it 'matches exact channel' do
        expect(manager.channel_matches_pattern?('/messages', '/messages')).to be true
        expect(manager.channel_matches_pattern?('/messages/1', '/messages')).to be false
      end
    end

    describe '#get_pattern_subscribers' do
      it 'returns subscribers matching wildcard patterns' do
        em_run do
          manager.subscribe('client-1', '/chat/*') do
            manager.get_pattern_subscribers('/chat/room1') do |clients|
              expect(clients).to include('client-1')
              EM.stop
            end
          end
        end
      end

      it 'handles multi-level wildcards' do
        em_run do
          manager.subscribe('client-1', '/chat/**') do
            manager.get_pattern_subscribers('/chat/room1/private') do |clients|
              expect(clients).to include('client-1')
              EM.stop
            end
          end
        end
      end
    end
  end

  describe '#cleanup_client_subscriptions' do
    it 'removes all subscriptions for a client' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          manager.subscribe('client-1', '/notifications') do
            manager.cleanup_client_subscriptions('client-1')

            EM.add_timer(0.1) do
              manager.get_client_subscriptions('client-1') do |channels|
                expect(channels).to be_empty
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe 'wildcard pattern storage' do
    it 'stores wildcard patterns in patterns set' do
      em_run do
        manager.subscribe('client-1', '/chat/*') do
          # Verify pattern was stored
          connection.with_redis do |redis|
            patterns = redis.smembers('test:patterns')
            expect(patterns).to include('/chat/*')
          end
          EM.stop
        end
      end
    end

    it 'does not store non-wildcard channels in patterns set' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          connection.with_redis do |redis|
            patterns = redis.smembers('test:patterns')
            expect(patterns).not_to include('/messages')
          end
          EM.stop
        end
      end
    end

    it 'cleans up wildcard pattern when last subscriber unsubscribes' do
      em_run do
        manager.subscribe('client-1', '/chat/*') do
          manager.subscribe('client-2', '/chat/*') do
            # Unsubscribe first client
            manager.unsubscribe('client-1', '/chat/*') do
              # Pattern should still exist
              connection.with_redis do |redis|
                patterns = redis.smembers('test:patterns')
                expect(patterns).to include('/chat/*')
              end

              # Unsubscribe last client
              manager.unsubscribe('client-2', '/chat/*') do
                # Pattern should be removed
                connection.with_redis do |redis|
                  patterns = redis.smembers('test:patterns')
                  expect(patterns).not_to include('/chat/*')
                end
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'keeps pattern when unsubscribing if other subscribers exist' do
      em_run do
        manager.subscribe('client-1', '/news/**') do
          manager.subscribe('client-2', '/news/**') do
            manager.unsubscribe('client-1', '/news/**') do
              # Pattern should still exist
              connection.with_redis do |redis|
                patterns = redis.smembers('test:patterns')
                expect(patterns).to include('/news/**')
              end
              EM.stop
            end
          end
        end
      end
    end
  end

  describe 'error handling' do
    it 'handles subscribe errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        manager.subscribe('client-1', '/messages') do |success|
          expect(success).to be false
          EM.stop
        end
      end
    end

    it 'handles unsubscribe errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        manager.unsubscribe('client-1', '/messages') do |success|
          expect(success).to be false
          EM.stop
        end
      end
    end

    it 'handles get_client_subscriptions errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        manager.get_client_subscriptions('client-1') do |channels|
          expect(channels).to eq([])
          EM.stop
        end
      end
    end

    it 'handles get_subscribers errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        manager.get_subscribers('/messages') do |clients|
          expect(clients).to eq([])
          EM.stop
        end
      end
    end

    it 'handles get_pattern_subscribers errors gracefully' do
      # Disconnect to cause error
      connection.disconnect

      clients = manager.get_pattern_subscribers('/chat/room1')
      expect(clients).to eq([])
    end

    it 'handles unsubscribe_all with no subscriptions' do
      em_run do
        manager.unsubscribe_all('client-with-no-subs') do |success|
          expect(success).to be true
          EM.stop
        end
      end
    end

    it 'handles unsubscribe_all errors gracefully' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          # Disconnect to cause error on unsubscribe_all
          connection.disconnect

          manager.unsubscribe_all('client-1') do |success|
            # Even with disconnected connection, unsubscribe_all handles the error
            # by getting empty subscriptions and returning success
            expect(success).to be true
            EM.stop
          end
        end
      end
    end
  end
end
