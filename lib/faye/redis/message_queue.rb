require 'json'
require 'securerandom'

module Faye
  class Redis
    class MessageQueue
      attr_reader :connection, :options

      def initialize(connection, options = {})
        @connection = connection
        @options = options
      end

      # Enqueue a message for a client
      def enqueue(client_id, message, &callback)
        # Add unique ID if not present (for message deduplication)
        message_with_id = message.dup
        message_with_id['id'] ||= generate_message_id

        # Store message directly as JSON
        message_json = message_with_id.to_json
        key = queue_key(client_id)

        @connection.with_redis do |redis|
          # Use Lua script to atomically RPUSH and set TTL only if key has no TTL
          # This prevents resetting TTL on every enqueue for hot queues
          redis.eval(<<~LUA, keys: [key], argv: [message_json, message_ttl.to_s])
            redis.call('RPUSH', KEYS[1], ARGV[1])
            local ttl = redis.call('TTL', KEYS[1])
            if ttl == -1 then
              redis.call('EXPIRE', KEYS[1], tonumber(ARGV[2]))
            end
            return 1
          LUA
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to enqueue message for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Dequeue all messages for a client
      def dequeue_all(client_id, &callback)
        # Get all messages and delete queue in a single atomic operation
        key = queue_key(client_id)

        json_messages = @connection.with_redis do |redis|
          # Use MULTI/EXEC to atomically get and delete
          redis.multi do |multi|
            multi.lrange(key, 0, -1)
            multi.del(key)
          end
        end

        # Parse messages from JSON
        messages = []
        if json_messages && json_messages[0]
          json_messages[0].each do |json|
            begin
              messages << JSON.parse(json)
            rescue JSON::ParserError => e
              log_error("Failed to parse message JSON: #{e.message}")
            end
          end
        end

        EventMachine.next_tick { callback.call(messages) } if callback
        messages
      rescue => e
        log_error("Failed to dequeue messages for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call([]) } if callback
        []
      end

      # Peek at messages without removing them
      def peek(client_id, limit = 10, &callback)
        json_messages = @connection.with_redis do |redis|
          redis.lrange(queue_key(client_id), 0, limit - 1)
        end

        messages = json_messages.map do |json|
          begin
            JSON.parse(json)
          rescue JSON::ParserError => e
            log_error("Failed to parse message JSON: #{e.message}")
            nil
          end
        end.compact

        EventMachine.next_tick { callback.call(messages) } if callback
        messages
      rescue => e
        log_error("Failed to peek messages for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call([]) } if callback
        []
      end

      # Get queue size for a client
      def size(client_id, &callback)
        queue_size = @connection.with_redis do |redis|
          redis.llen(queue_key(client_id))
        end

        EventMachine.next_tick { callback.call(queue_size) } if callback
        queue_size
      rescue => e
        log_error("Failed to get queue size for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(0) } if callback
        0
      end

      # Clear a client's message queue
      def clear(client_id, &callback)
        # Simply delete the queue
        @connection.with_redis do |redis|
          redis.del(queue_key(client_id))
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to clear queue for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      private

      def queue_key(client_id)
        namespace_key("messages:#{client_id}")
      end

      def namespace_key(key)
        namespace = @options[:namespace] || 'faye'
        "#{namespace}:#{key}"
      end

      def message_ttl
        @options[:message_ttl] || 3600
      end

      def generate_message_id
        SecureRandom.uuid
      end

      def log_error(message)
        puts "[Faye::Redis::MessageQueue] ERROR: #{message}" if @options[:log_level] != :silent
      end
    end
  end
end
