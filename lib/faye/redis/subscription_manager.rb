module Faye
  class Redis
    class SubscriptionManager
      attr_reader :connection, :options

      def initialize(connection, options = {})
        @connection = connection
        @options = options
        @pattern_cache = {}  # Cache compiled regexes for pattern matching performance
      end

      # Subscribe a client to a channel
      def subscribe(client_id, channel, &callback)
        timestamp = Time.now.to_i
        subscription_ttl = @options[:subscription_ttl] || 86400  # 24 hours default

        client_subs_key = client_subscriptions_key(client_id)
        channel_subs_key = channel_subscribers_key(channel)
        sub_key = subscription_key(client_id, channel)

        @connection.with_redis do |redis|
          # Use Lua script to atomically add subscriptions and set TTL only if keys have no TTL
          # This prevents resetting TTL on re-subscription
          redis.eval(<<-LUA, keys: [client_subs_key, channel_subs_key, sub_key], argv: [channel, client_id, timestamp.to_s, subscription_ttl])
            -- Add channel to client's subscriptions
            redis.call('SADD', KEYS[1], ARGV[1])
            local ttl1 = redis.call('TTL', KEYS[1])
            if ttl1 == -1 then
              redis.call('EXPIRE', KEYS[1], ARGV[4])
            end

            -- Add client to channel's subscribers
            redis.call('SADD', KEYS[2], ARGV[2])
            local ttl2 = redis.call('TTL', KEYS[2])
            if ttl2 == -1 then
              redis.call('EXPIRE', KEYS[2], ARGV[4])
            end

            -- Store subscription metadata
            redis.call('HSET', KEYS[3], 'subscribed_at', ARGV[3], 'channel', ARGV[1], 'client_id', ARGV[2])
            local ttl3 = redis.call('TTL', KEYS[3])
            if ttl3 == -1 then
              redis.call('EXPIRE', KEYS[3], ARGV[4])
            end

            return 1
          LUA

          # Handle wildcard patterns separately
          if channel.include?('*')
            redis.eval(<<-LUA, keys: [patterns_key], argv: [channel, subscription_ttl])
              redis.call('SADD', KEYS[1], ARGV[1])
              local ttl = redis.call('TTL', KEYS[1])
              if ttl == -1 then
                redis.call('EXPIRE', KEYS[1], ARGV[2])
              end
              return 1
            LUA
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
            multi.srem?(client_subscriptions_key(client_id), channel)

            # Remove client from channel's subscribers
            multi.srem?(channel_subscribers_key(channel), client_id)

            # Delete subscription metadata
            multi.del(subscription_key(client_id, channel))
          end
        end

        # Clean up wildcard pattern if no more subscribers
        if channel.include?('*')
          cleanup_pattern_if_unused(channel)
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
            callback_called = false  # Prevent race condition
            channels.each do |channel|
              unsubscribe(client_id, channel) do
                remaining -= 1
                # Check flag to prevent multiple callback invocations
                if remaining == 0 && !callback_called && callback
                  callback_called = true
                  callback.call(true)
                end
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

        # Filter to only matching patterns first
        matching_patterns = patterns.select { |pattern| channel_matches_pattern?(channel, pattern) }
        return [] if matching_patterns.empty?

        # Use pipelining to fetch all matching pattern subscribers in one network round-trip
        results = @connection.with_redis do |redis|
          redis.pipelined do |pipeline|
            matching_patterns.each do |pattern|
              pipeline.smembers(channel_subscribers_key(pattern))
            end
          end
        end

        # Flatten and deduplicate results
        results.flatten.uniq
      rescue => e
        log_error("Failed to get pattern subscribers for channel #{channel}: #{e.message}")
        []
      end

      # Check if a channel matches a pattern
      # Uses memoization to cache compiled regexes for performance
      def channel_matches_pattern?(channel, pattern)
        # Get or compile regex for this pattern
        regex = @pattern_cache[pattern] ||= begin
          # Escape the pattern first to handle special regex characters
          # Then replace escaped wildcards with regex patterns
          # ** matches multiple segments (including /), * matches one segment (no /)
          escaped = Regexp.escape(pattern)

          regex_pattern = escaped
            .gsub(Regexp.escape('**'), '.*')        # ** → .* (match anything)
            .gsub(Regexp.escape('*'), '[^/]+')      # * → [^/]+ (match one segment)

          Regexp.new("^#{regex_pattern}$")
        end

        !!(channel =~ regex)
      rescue RegexpError => e
        log_error("Invalid pattern #{pattern}: #{e.message}")
        false
      end

      # Clean up subscriptions for a client
      def cleanup_client_subscriptions(client_id)
        unsubscribe_all(client_id)
      end

      # Comprehensive cleanup of orphaned subscription data
      # This should be called periodically during garbage collection
      # Processes in batches to avoid blocking the connection pool
      def cleanup_orphaned_data(active_client_ids, &callback)
        active_set = active_client_ids.to_set
        namespace = @options[:namespace] || 'faye'
        batch_size = @options[:cleanup_batch_size] || 50

        # Validate and clamp batch_size to safe range (1-1000)
        batch_size = [[batch_size.to_i, 1].max, 1000].min

        # Phase 1: Scan for orphaned subscriptions
        scan_orphaned_subscriptions(active_set, namespace) do |orphaned_subscriptions|
          # Phase 2: Clean up orphaned subscriptions in batches
          cleanup_orphaned_subscriptions_batched(orphaned_subscriptions, namespace, batch_size) do
            # Phase 3: Clean up orphaned message queues
            cleanup_orphaned_message_queues_async(active_set, namespace, batch_size) do
              # Phase 4: Clean up empty channels (yields between operations)
              cleanup_empty_channels_async(namespace) do
                # Phase 5: Clean up unused patterns
                cleanup_unused_patterns_async do
                  callback.call if callback
                end
              end
            end
          end
        end
      rescue => e
        log_error("Failed to cleanup orphaned data: #{e.message}")
        EventMachine.next_tick { callback.call } if callback
      end

      private

      # Scan for orphaned subscription keys
      # Uses batched scanning to avoid holding connection for long periods
      def scan_orphaned_subscriptions(active_set, namespace, &callback)
        orphaned_subscriptions = []

        # Batch scan to release connection between iterations
        scan_batch = lambda do |cursor_value|
          begin
            @connection.with_redis do |redis|
              cursor, keys = redis.scan(cursor_value, match: "#{namespace}:subscriptions:*", count: 100)

              keys.each do |key|
                client_id = key.split(':').last
                orphaned_subscriptions << client_id unless active_set.include?(client_id)
              end

              if cursor == "0"
                # Scan complete
                EventMachine.next_tick { callback.call(orphaned_subscriptions) }
              else
                # Continue scanning in next tick to release connection
                EventMachine.next_tick { scan_batch.call(cursor) }
              end
            end
          rescue => e
            log_error("Failed to scan orphaned subscriptions batch: #{e.message}")
            EventMachine.next_tick { callback.call(orphaned_subscriptions) }
          end
        end

        scan_batch.call("0")
      rescue => e
        log_error("Failed to scan orphaned subscriptions: #{e.message}")
        EventMachine.next_tick { callback.call([]) }
      end

      # Clean up orphaned subscriptions in batches to avoid blocking
      def cleanup_orphaned_subscriptions_batched(orphaned_subscriptions, namespace, batch_size, &callback)
        return EventMachine.next_tick { callback.call } if orphaned_subscriptions.empty?

        total = orphaned_subscriptions.size
        batches = orphaned_subscriptions.each_slice(batch_size).to_a
        processed = 0

        process_batch = lambda do |batch_index|
          if batch_index >= batches.size
            puts "[Faye::Redis::SubscriptionManager] INFO: Cleaned up #{total} orphaned subscription sets" if @options[:log_level] != :silent
            EventMachine.next_tick { callback.call }
            return
          end

          batch = batches[batch_index]

          @connection.with_redis do |redis|
            batch.each do |client_id|
              channels = redis.smembers(client_subscriptions_key(client_id))

              redis.pipelined do |pipeline|
                pipeline.del(client_subscriptions_key(client_id))

                channels.each do |channel|
                  pipeline.del(subscription_key(client_id, channel))
                  pipeline.srem(channel_subscribers_key(channel), client_id)
                end

                pipeline.del("#{namespace}:messages:#{client_id}")
              end
            end
          end

          processed += batch.size

          # Yield control to EventMachine between batches
          EventMachine.next_tick { process_batch.call(batch_index + 1) }
        end

        process_batch.call(0)
      rescue => e
        log_error("Failed to cleanup orphaned subscriptions batch: #{e.message}")
        EventMachine.next_tick { callback.call }
      end

      # Clean up orphaned message queues for non-existent clients
      # Scans for message queues that belong to clients not in the active set
      def cleanup_orphaned_message_queues_async(active_set, namespace, batch_size, &callback)
        orphaned_queues = []

        # Batch scan to avoid holding connection
        scan_batch = lambda do |cursor_value|
          begin
            @connection.with_redis do |redis|
              cursor, keys = redis.scan(cursor_value, match: "#{namespace}:messages:*", count: 100)

              keys.each do |key|
                client_id = key.split(':').last
                orphaned_queues << key unless active_set.include?(client_id)
              end

              if cursor == "0"
                # Scan complete, now clean up in batches
                if orphaned_queues.any?
                  cleanup_message_queues_batched(orphaned_queues, batch_size) do
                    EventMachine.next_tick { callback.call }
                  end
                else
                  EventMachine.next_tick { callback.call }
                end
              else
                # Continue scanning
                EventMachine.next_tick { scan_batch.call(cursor) }
              end
            end
          rescue => e
            log_error("Failed to scan orphaned message queues: #{e.message}")
            EventMachine.next_tick { callback.call }
          end
        end

        scan_batch.call("0")
      rescue => e
        log_error("Failed to cleanup orphaned message queues: #{e.message}")
        EventMachine.next_tick { callback.call }
      end

      # Delete message queues in batches
      def cleanup_message_queues_batched(queue_keys, batch_size, &callback)
        return EventMachine.next_tick { callback.call } if queue_keys.empty?

        total = queue_keys.size
        batches = queue_keys.each_slice(batch_size).to_a

        process_batch = lambda do |batch_index|
          if batch_index >= batches.size
            puts "[Faye::Redis::SubscriptionManager] INFO: Cleaned up #{total} orphaned message queues" if @options[:log_level] != :silent
            EventMachine.next_tick { callback.call }
            return
          end

          batch = batches[batch_index]

          @connection.with_redis do |redis|
            redis.pipelined do |pipeline|
              batch.each { |key| pipeline.del(key) }
            end
          end

          # Yield control between batches
          EventMachine.next_tick { process_batch.call(batch_index + 1) }
        end

        process_batch.call(0)
      rescue => e
        log_error("Failed to cleanup message queues batch: #{e.message}")
        EventMachine.next_tick { callback.call }
      end

      # Async version of cleanup_empty_channels that yields between operations
      def cleanup_empty_channels_async(namespace, &callback)
        @connection.with_redis do |redis|
          cursor = "0"
          empty_channels = []

          loop do
            cursor, keys = redis.scan(cursor, match: "#{namespace}:channels:*", count: 100)

            keys.each do |key|
              count = redis.scard(key)
              empty_channels << key if count == 0
            end

            break if cursor == "0"
          end

          if empty_channels.any?
            redis.pipelined do |pipeline|
              empty_channels.each { |key| pipeline.del(key) }
            end
            puts "[Faye::Redis::SubscriptionManager] INFO: Cleaned up #{empty_channels.size} empty channel Sets" if @options[:log_level] != :silent
          end

          EventMachine.next_tick { callback.call }
        end
      rescue => e
        log_error("Failed to cleanup empty channels: #{e.message}")
        EventMachine.next_tick { callback.call }
      end

      # Async version of cleanup_unused_patterns that yields after completion
      def cleanup_unused_patterns_async(&callback)
        @connection.with_redis do |redis|
          patterns = redis.smembers(patterns_key)
          unused_patterns = []

          patterns.each do |pattern|
            count = redis.scard(channel_subscribers_key(pattern))
            unused_patterns << pattern if count == 0
          end

          if unused_patterns.any?
            redis.pipelined do |pipeline|
              unused_patterns.each do |pattern|
                pipeline.srem(patterns_key, pattern)
                pipeline.del(channel_subscribers_key(pattern))
              end
            end
            # Clear unused patterns from regex cache
            unused_patterns.each { |pattern| @pattern_cache.delete(pattern) }
            puts "[Faye::Redis::SubscriptionManager] INFO: Cleaned up #{unused_patterns.size} unused patterns" if @options[:log_level] != :silent
          end

          EventMachine.next_tick { callback.call }
        end
      rescue => e
        log_error("Failed to cleanup unused patterns: #{e.message}")
        EventMachine.next_tick { callback.call }
      end

      # Clean up channel Sets that have no subscribers
      def cleanup_empty_channels(redis, namespace)
        cursor = "0"
        empty_channels = []

        loop do
          cursor, keys = redis.scan(cursor, match: "#{namespace}:channels:*", count: 100)

          keys.each do |key|
            count = redis.scard(key)
            empty_channels << key if count == 0
          end

          break if cursor == "0"
        end

        if empty_channels.any?
          redis.pipelined do |pipeline|
            empty_channels.each { |key| pipeline.del(key) }
          end
          puts "[Faye::Redis::SubscriptionManager] INFO: Cleaned up #{empty_channels.size} empty channel Sets" if @options[:log_level] != :silent
        end
      rescue => e
        log_error("Failed to cleanup empty channels: #{e.message}")
      end

      # Clean up patterns that have no subscribers
      def cleanup_unused_patterns(redis)
        patterns = redis.smembers(patterns_key)
        unused_patterns = []

        patterns.each do |pattern|
          count = redis.scard(channel_subscribers_key(pattern))
          unused_patterns << pattern if count == 0
        end

        if unused_patterns.any?
          redis.pipelined do |pipeline|
            unused_patterns.each do |pattern|
              pipeline.srem(patterns_key, pattern)
              pipeline.del(channel_subscribers_key(pattern))
            end
          end
          # Clear unused patterns from regex cache
          unused_patterns.each { |pattern| @pattern_cache.delete(pattern) }
          puts "[Faye::Redis::SubscriptionManager] INFO: Cleaned up #{unused_patterns.size} unused patterns" if @options[:log_level] != :silent
        end
      rescue => e
        log_error("Failed to cleanup unused patterns: #{e.message}")
      end

      def cleanup_pattern_if_unused(pattern)
        subscribers = @connection.with_redis do |redis|
          redis.smembers(channel_subscribers_key(pattern))
        end

        if subscribers.empty?
          @connection.with_redis do |redis|
            redis.srem(patterns_key, pattern)
          end
          # Clear pattern from regex cache when it's removed
          @pattern_cache.delete(pattern)
        end
      rescue => e
        log_error("Failed to cleanup pattern #{pattern}: #{e.message}")
      end

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
