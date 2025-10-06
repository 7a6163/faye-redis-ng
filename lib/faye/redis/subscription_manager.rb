module Faye
  class Redis
    class SubscriptionManager
      attr_reader :connection, :options

      def initialize(connection, options = {})
        @connection = connection
        @options = options
      end

      # Subscribe a client to a channel
      def subscribe(client_id, channel, &callback)
        timestamp = Time.now.to_i

        @connection.with_redis do |redis|
          redis.multi do |multi|
            # Add channel to client's subscriptions
            multi.sadd(client_subscriptions_key(client_id), channel)

            # Add client to channel's subscribers
            multi.sadd(channel_subscribers_key(channel), client_id)

            # Store subscription metadata
            multi.hset(
              subscription_key(client_id, channel),
              'subscribed_at', timestamp,
              'channel', channel,
              'client_id', client_id
            )

            # Handle wildcard patterns
            if channel.include?('*')
              multi.sadd(patterns_key, channel)
            end
          end
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to subscribe client #{client_id} to #{channel}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Unsubscribe a client from a channel
      def unsubscribe(client_id, channel, &callback)
        @connection.with_redis do |redis|
          redis.multi do |multi|
            # Remove channel from client's subscriptions
            multi.srem(client_subscriptions_key(client_id), channel)

            # Remove client from channel's subscribers
            multi.srem(channel_subscribers_key(channel), client_id)

            # Delete subscription metadata
            multi.del(subscription_key(client_id, channel))
          end
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to unsubscribe client #{client_id} from #{channel}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Unsubscribe a client from all channels
      def unsubscribe_all(client_id, &callback)
        # Get all channels the client is subscribed to
        get_client_subscriptions(client_id) do |channels|
          if channels.empty?
            callback.call(true) if callback
          else
            # Unsubscribe from each channel
            remaining = channels.size
            channels.each do |channel|
              unsubscribe(client_id, channel) do
                remaining -= 1
                callback.call(true) if callback && remaining == 0
              end
            end
          end
        end
      rescue => e
        log_error("Failed to unsubscribe client #{client_id} from all channels: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Get all channels a client is subscribed to
      def get_client_subscriptions(client_id, &callback)
        channels = @connection.with_redis do |redis|
          redis.smembers(client_subscriptions_key(client_id))
        end

        EventMachine.next_tick { callback.call(channels) } if callback
        channels
      rescue => e
        log_error("Failed to get subscriptions for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call([]) } if callback
        []
      end

      # Get all clients subscribed to a channel
      def get_subscribers(channel, &callback)
        # Get direct subscribers
        direct_subscribers = @connection.with_redis do |redis|
          redis.smembers(channel_subscribers_key(channel))
        end

        # Get pattern subscribers
        pattern_subscribers = get_pattern_subscribers(channel)

        all_subscribers = (direct_subscribers + pattern_subscribers).uniq

        EventMachine.next_tick { callback.call(all_subscribers) } if callback
        all_subscribers
      rescue => e
        log_error("Failed to get subscribers for channel #{channel}: #{e.message}")
        EventMachine.next_tick { callback.call([]) } if callback
        []
      end

      # Get subscribers matching wildcard patterns
      def get_pattern_subscribers(channel)
        patterns = @connection.with_redis do |redis|
          redis.smembers(patterns_key)
        end

        matching_clients = []
        patterns.each do |pattern|
          if channel_matches_pattern?(channel, pattern)
            clients = @connection.with_redis do |redis|
              redis.smembers(channel_subscribers_key(pattern))
            end
            matching_clients.concat(clients)
          end
        end

        matching_clients.uniq
      rescue => e
        log_error("Failed to get pattern subscribers for channel #{channel}: #{e.message}")
        []
      end

      # Check if a channel matches a pattern
      def channel_matches_pattern?(channel, pattern)
        # Convert Faye wildcard pattern to regex
        # * matches one segment, ** matches multiple segments
        regex_pattern = pattern
          .gsub('**', '__DOUBLE_STAR__')
          .gsub('*', '[^/]+')
          .gsub('__DOUBLE_STAR__', '.*')

        regex = Regexp.new("^#{regex_pattern}$")
        !!(channel =~ regex)
      end

      # Clean up subscriptions for a client
      def cleanup_client_subscriptions(client_id)
        unsubscribe_all(client_id)
      end

      private

      def client_subscriptions_key(client_id)
        namespace_key("subscriptions:#{client_id}")
      end

      def channel_subscribers_key(channel)
        namespace_key("channels:#{channel}")
      end

      def subscription_key(client_id, channel)
        namespace_key("subscription:#{client_id}:#{channel}")
      end

      def patterns_key
        namespace_key('patterns')
      end

      def namespace_key(key)
        namespace = @options[:namespace] || 'faye'
        "#{namespace}:#{key}"
      end

      def log_error(message)
        puts "[Faye::Redis::SubscriptionManager] ERROR: #{message}" if @options[:log_level] != :silent
      end
    end
  end
end
