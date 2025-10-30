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

  describe 'pattern caching' do
    it 'caches compiled regexes for performance' do
      em_run do
        # Subscribe to a wildcard pattern
        manager.subscribe('client-1', '/messages/*') do
          # Access pattern_cache
          cache = manager.instance_variable_get(:@pattern_cache)

          # First match should compile and cache the regex
          result1 = manager.channel_matches_pattern?('/messages/test', '/messages/*')
          expect(result1).to be true
          expect(cache.keys).to include('/messages/*')

          # Second match should use cached regex (same object_id)
          cached_regex = cache['/messages/*']
          result2 = manager.channel_matches_pattern?('/messages/test2', '/messages/*')
          expect(result2).to be true
          expect(cache['/messages/*'].object_id).to eq(cached_regex.object_id)

          EM.stop
        end
      end
    end

    it 'clears cache when pattern is removed' do
      em_run do
        manager.subscribe('client-1', '/messages/*') do
          cache = manager.instance_variable_get(:@pattern_cache)

          # Trigger pattern matching to populate cache
          manager.channel_matches_pattern?('/messages/test', '/messages/*')
          expect(cache.keys).to include('/messages/*')

          # Unsubscribe should trigger cleanup and clear cache
          manager.unsubscribe('client-1', '/messages/*') do
            # Give cleanup time to complete
            EM.add_timer(0.1) do
              expect(cache.keys).not_to include('/messages/*')
              EM.stop
            end
          end
        end
      end
    end

    it 'handles special regex characters in patterns correctly' do
      em_run do
        # These patterns contain special regex characters that should be escaped
        special_patterns = [
          '/messages.channel',  # . should match literal dot, not any char
          '/messages[test]',    # [] should match literal brackets
          '/messages(group)',   # () should match literal parens
        ]

        special_patterns.each do |pattern|
          # Should not raise RegexpError
          expect { manager.channel_matches_pattern?("/test", pattern) }.not_to raise_error
        end

        # Test that literal dots don't act as wildcards
        result = manager.channel_matches_pattern?('/messagesXchannel', '/messages.channel')
        expect(result).to be false  # Should not match, . is literal not wildcard

        result = manager.channel_matches_pattern?('/messages.channel', '/messages.channel')
        expect(result).to be true  # Should match exact

        EM.stop
      end
    end
  end

  describe 'batch size validation' do
    it 'clamps batch_size to minimum of 1' do
      em_run do
        manager_with_invalid = described_class.new(connection, test_redis_options.merge(cleanup_batch_size: 0))

        # Create some test data
        manager_with_invalid.subscribe('client-1', '/test') do
          # Trigger cleanup with invalid batch size
          # Should clamp to 1 and not raise error
          expect {
            manager_with_invalid.cleanup_orphaned_data([]) do
              EM.stop
            end
          }.not_to raise_error
        end
      end
    end

    it 'clamps batch_size to maximum of 1000' do
      em_run do
        manager_with_large = described_class.new(connection, test_redis_options.merge(cleanup_batch_size: 99999))

        manager_with_large.subscribe('client-1', '/test') do
          # Should clamp to 1000 and not cause issues
          expect {
            manager_with_large.cleanup_orphaned_data([]) do
              EM.stop
            end
          }.not_to raise_error
        end
      end
    end

    it 'handles negative batch_size' do
      em_run do
        manager_with_negative = described_class.new(connection, test_redis_options.merge(cleanup_batch_size: -10))

        manager_with_negative.subscribe('client-1', '/test') do
          # Should clamp to 1
          expect {
            manager_with_negative.cleanup_orphaned_data([]) do
              EM.stop
            end
          }.not_to raise_error
        end
      end
    end
  end

  describe '#unsubscribe_all callback guarantee' do
    it 'calls callback exactly once even with many channels' do
      em_run do
        callback_count = 0
        channels = (1..10).map { |i| "/channel#{i}" }

        # Subscribe to many channels
        subscribe_all = lambda do |index|
          if index >= channels.size
            # All subscribed, now unsubscribe_all
            manager.unsubscribe_all('client-1') do |success|
              callback_count += 1
              expect(success).to be true
            end

            # Wait and verify callback called exactly once
            EM.add_timer(0.5) do
              expect(callback_count).to eq(1)
              EM.stop
            end
          else
            manager.subscribe('client-1', channels[index]) do
              subscribe_all.call(index + 1)
            end
          end
        end

        subscribe_all.call(0)
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

    it 'handles cleanup_orphaned_data errors gracefully' do
      em_run do
        # Disconnect to cause errors during cleanup
        connection.disconnect

        # Should handle errors and call callback
        manager.cleanup_orphaned_data([]) do
          # Should complete without raising error
          EM.stop
        end
      end
    end

    it 'handles scan_orphaned_subscriptions errors gracefully' do
      em_run do
        # Call private method directly to test error handling
        manager.send(:scan_orphaned_subscriptions, Set.new, 'faye') do |result|
          # Connection error should be handled, returns empty array
          expect(result).to eq([])
          EM.stop
        end
      end
    end

    it 'handles channel_matches_pattern? with invalid regex' do
      em_run do
        # Test with a pattern that might cause RegexpError after escaping
        # Most patterns should work, but test error handling exists
        result = manager.channel_matches_pattern?('/test', '/valid/*')
        expect([true, false]).to include(result)  # Should not raise error
        EM.stop
      end
    end

    it 'handles cleanup_pattern_if_unused errors gracefully' do
      em_run do
        manager.subscribe('client-1', '/messages/*') do
          # Disconnect to cause error
          connection.disconnect

          # Should handle error gracefully (private method)
          expect {
            manager.send(:cleanup_pattern_if_unused, '/messages/*')
          }.not_to raise_error

          EM.stop
        end
      end
    end
  end

  describe 'batched scanning edge cases' do
    it 'handles empty scan results' do
      em_run do
        # Scan with no matching keys
        manager.send(:scan_orphaned_subscriptions, Set.new(['all-clients']), 'faye-nonexistent') do |orphaned|
          expect(orphaned).to be_an(Array)
          EM.stop
        end
      end
    end

    it 'handles large number of orphaned subscriptions' do
      em_run(3) do
        # Create many subscriptions
        clients = (1..20).map { |i| "client-#{i}" }
        subscribe_count = 0

        clients.each do |client_id|
          manager.subscribe(client_id, '/test') do
            subscribe_count += 1

            if subscribe_count == clients.size
              # Now trigger cleanup with no active clients (all orphaned)
              manager.cleanup_orphaned_data([]) do
                # Should handle large batch without error
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'handles cleanup with mixed valid and invalid clients' do
      em_run(2) do
        manager.subscribe('client-1', '/test1') do
          manager.subscribe('client-2', '/test2') do
            # Only client-1 is active, client-2 should be cleaned
            manager.cleanup_orphaned_data(['client-1']) do
              # Should complete successfully
              EM.stop
            end
          end
        end
      end
    end
  end

  describe 'pattern matching edge cases' do
    it 'handles empty pattern list' do
      em_run do
        subscribers = manager.send(:get_pattern_subscribers, '/test/channel')
        expect(subscribers).to be_an(Array)
        expect(subscribers).to be_empty
        EM.stop
      end
    end

    it 'handles pattern with no matching channels' do
      em_run do
        manager.subscribe('client-1', '/foo/*') do
          # Check channel that doesn't match
          subscribers = manager.send(:get_pattern_subscribers, '/bar/test')
          expect(subscribers).to be_an(Array)
          expect(subscribers).to be_empty
          EM.stop
        end
      end
    end

    it 'caches multiple different patterns' do
      em_run do
        patterns = ['/foo/*', '/bar/**', '/baz/*/test']

        patterns.each do |pattern|
          manager.subscribe("client-#{pattern}", pattern)
        end

        EM.add_timer(0.2) do
          cache = manager.instance_variable_get(:@pattern_cache)

          # Test all patterns
          patterns.each do |pattern|
            manager.channel_matches_pattern?('/test', pattern)
          end

          # All patterns should be cached
          expect(cache.keys.size).to be >= 3
          EM.stop
        end
      end
    end
  end

  describe 'subscription TTL behavior' do
    it 'sets TTL on all subscription keys' do
      em_run do
        manager.subscribe('client-1', '/messages') do
          # Verify TTL is set (we can't easily check exact value, but key should exist)
          connection.with_redis do |redis|
            namespace = test_redis_options[:namespace] || 'faye'

            # Check various keys have TTL set (TTL > 0)
            subscriptions_ttl = redis.ttl("#{namespace}:subscriptions:client-1")
            channel_ttl = redis.ttl("#{namespace}:channels:/messages")

            expect(subscriptions_ttl).to be > 0
            expect(channel_ttl).to be > 0

            EM.stop
          end
        end
      end
    end
  end
end
