require 'json'

module Faye
  class Redis
    class ClientRegistry
      attr_reader :connection, :options

      def initialize(connection, options = {})
        @connection = connection
        @options = options
      end

      # Create a new client
      def create(client_id, &callback)
        timestamp = Time.now.to_i
        client_data = {
          client_id: client_id,
          created_at: timestamp,
          last_ping: timestamp,
          server_id: server_id
        }

        @connection.with_redis do |redis|
          redis.multi do |multi|
            multi.hset(client_key(client_id), client_data.transform_keys(&:to_s))
            multi.sadd?(clients_index_key, client_id)
            multi.expire(client_key(client_id), client_timeout)
          end
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to create client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Destroy a client
      def destroy(client_id, &callback)
        @connection.with_redis do |redis|
          redis.multi do |multi|
            multi.del(client_key(client_id))
            multi.srem?(clients_index_key, client_id)
          end
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to destroy client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Check if a client exists
      def exists?(client_id, &callback)
        result = @connection.with_redis do |redis|
          redis.exists?(client_key(client_id))
        end

        # Redis 5.x returns boolean, older versions return integer
        exists = result.is_a?(Integer) ? result > 0 : result

        EventMachine.next_tick { callback.call(exists) } if callback
        exists
      rescue => e
        log_error("Failed to check client existence #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
        false
      end

      # Ping a client to keep it alive
      def ping(client_id)
        timestamp = Time.now.to_i

        @connection.with_redis do |redis|
          redis.multi do |multi|
            multi.hset(client_key(client_id), 'last_ping', timestamp)
            multi.expire(client_key(client_id), client_timeout)
          end
        end
      rescue => e
        log_error("Failed to ping client #{client_id}: #{e.message}")
      end

      # Get client data
      def get(client_id, &callback)
        data = @connection.with_redis do |redis|
          redis.hgetall(client_key(client_id))
        end

        client_data = data.empty? ? nil : symbolize_keys(data)
        EventMachine.next_tick { callback.call(client_data) } if callback
        client_data
      rescue => e
        log_error("Failed to get client #{client_id}: #{e.message}")
        EventMachine.next_tick { callback.call(nil) } if callback
        nil
      end

      # Get all active clients
      def all(&callback)
        client_ids = @connection.with_redis do |redis|
          redis.smembers(clients_index_key)
        end

        EventMachine.next_tick { callback.call(client_ids) } if callback
        client_ids
      rescue => e
        log_error("Failed to get all clients: #{e.message}")
        EventMachine.next_tick { callback.call([]) } if callback
        []
      end

      # Clean up expired clients
      def cleanup_expired(&callback)
        all do |client_ids|
          # Check existence in batch using pipelined commands
          results = @connection.with_redis do |redis|
            redis.pipelined do |pipeline|
              client_ids.each do |client_id|
                pipeline.exists?(client_key(client_id))
              end
            end
          end

          # Collect expired client IDs
          expired_clients = []
          client_ids.each_with_index do |client_id, index|
            result = results[index]
            # Redis 5.x returns boolean, older versions return integer
            exists = result.is_a?(Integer) ? result > 0 : result
            expired_clients << client_id unless exists
          end

          # Batch delete expired clients
          if expired_clients.any?
            @connection.with_redis do |redis|
              redis.pipelined do |pipeline|
                expired_clients.each do |client_id|
                  pipeline.del(client_key(client_id))
                  pipeline.srem?(clients_index_key, client_id)
                end
              end
            end
          end

          EventMachine.next_tick { callback.call(expired_clients.size) } if callback
        end
      rescue => e
        log_error("Failed to cleanup expired clients: #{e.message}")
        EventMachine.next_tick { callback.call(0) } if callback
      end

      private

      def client_key(client_id)
        namespace_key("clients:#{client_id}")
      end

      def clients_index_key
        namespace_key('clients:index')
      end

      def namespace_key(key)
        namespace = @options[:namespace] || 'faye'
        "#{namespace}:#{key}"
      end

      def client_timeout
        @options[:client_timeout] || 60
      end

      def server_id
        @server_id ||= "server-#{Socket.gethostname}-#{Process.pid}"
      end

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end

      def log_error(message)
        puts "[Faye::Redis::ClientRegistry] ERROR: #{message}" if @options[:log_level] != :silent
      end
    end
  end
end
