require 'json'

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
        message_id = generate_message_id
        timestamp = Time.now.to_i

        message_data = {
          id: message_id,
          channel: message['channel'],
          data: message['data'],
          client_id: message['clientId'],
          timestamp: timestamp
        }

        @connection.with_redis do |redis|
          redis.multi do |multi|
            # Store message data
            multi.hset(message_key(message_id), message_data.transform_keys(&:to_s).transform_values { |v| v.to_json })

            # Add message to client's queue
            multi.rpush(queue_key(client_id), message_id)

            # Set TTL on message
            multi.expire(message_key(message_id), message_ttl)

            # Set TTL on queue
            multi.expire(queue_key(client_id), message_ttl)
          end
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to enqueue message for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Dequeue all messages for a client
      def dequeue_all(client_id, &callback)
        # Get all message IDs from queue
        message_ids = @connection.with_redis do |redis|
          redis.lrange(queue_key(client_id), 0, -1)
        end

        # Fetch all messages
        messages = message_ids.map do |message_id|
          fetch_message(message_id)
        end.compact

        # Clear the queue
        @connection.with_redis do |redis|
          redis.del(queue_key(client_id))
        end

        # Delete message data
        message_ids.each do |message_id|
          @connection.with_redis do |redis|
            redis.del(message_key(message_id))
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
        message_ids = @connection.with_redis do |redis|
          redis.lrange(queue_key(client_id), 0, limit - 1)
        end

        messages = message_ids.map do |message_id|
          fetch_message(message_id)
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
        @connection.with_redis do |redis|
          redis.del(queue_key(client_id))
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to clear queue for client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      private

      def fetch_message(message_id)
        data = @connection.with_redis do |redis|
          redis.hgetall(message_key(message_id))
        end

        return nil if data.empty?

        # Parse JSON values
        parsed_data = data.transform_values do |v|
          begin
            JSON.parse(v)
          rescue JSON::ParserError
            v
          end
        end

        # Convert to Faye message format
        {
          'channel' => parsed_data['channel'],
          'data' => parsed_data['data'],
          'clientId' => parsed_data['client_id'],
          'id' => parsed_data['id']
        }
      rescue => e
        log_error("Failed to fetch message #{message_id}: #{e.message}")
        nil
      end

      def queue_key(client_id)
        namespace_key("messages:#{client_id}")
      end

      def message_key(message_id)
        namespace_key("message:#{message_id}")
      end

      def namespace_key(key)
        namespace = @options[:namespace] || 'faye'
        "#{namespace}:#{key}"
      end

      def message_ttl
        @options[:message_ttl] || 3600
      end

      def generate_message_id
        "msg_#{Time.now.to_i}_#{rand(1000000)}"
      end

      def log_error(message)
        puts "[Faye::Redis::MessageQueue] ERROR: #{message}" if @options[:log_level] != :silent
      end
    end
  end
end
