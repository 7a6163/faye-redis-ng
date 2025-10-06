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
end
