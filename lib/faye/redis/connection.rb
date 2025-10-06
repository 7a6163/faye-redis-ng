require 'redis'
require 'connection_pool'

module Faye
  class Redis
    class Connection
      class ConnectionError < StandardError; end

      attr_reader :options

      def initialize(options = {})
        @options = options
        @pool = create_connection_pool
      end

      # Execute a Redis command with connection pooling
      def with_redis(&block)
        with_retry do
          @pool.with(&block)
        end
      end

      # Check if connected to Redis
      def connected?
        with_redis { |redis| redis.ping == 'PONG' }
      rescue ::Redis::ConnectionError, ::Redis::TimeoutError, Faye::Redis::Connection::ConnectionError, EOFError => e
        false
      end

      # Ping Redis server
      def ping
        with_redis { |redis| redis.ping }
      end

      # Disconnect from Redis
      def disconnect
        @pool.shutdown { |redis| redis.quit rescue nil }
      end

      # Get a dedicated Redis connection for pub/sub (not from pool)
      def create_pubsub_connection
        create_redis_client
      end

      private

      def create_connection_pool
        pool_size = @options[:pool_size] || 5
        pool_timeout = @options[:pool_timeout] || 5

        ConnectionPool.new(size: pool_size, timeout: pool_timeout) do
          create_redis_client
        end
      end

      def create_redis_client
        redis_options = {
          host: @options[:host] || 'localhost',
          port: @options[:port] || 6379,
          db: @options[:database] || 0,
          connect_timeout: @options[:connect_timeout] || 1,
          read_timeout: @options[:read_timeout] || 1,
          write_timeout: @options[:write_timeout] || 1
        }

        redis_options[:password] = @options[:password] if @options[:password]

        # SSL/TLS configuration
        if @options[:ssl] && @options[:ssl][:enabled]
          redis_options[:ssl] = true
          redis_options[:ssl_params] = {
            cert: @options[:ssl][:cert_file],
            key: @options[:ssl][:key_file],
            ca_file: @options[:ssl][:ca_file]
          }.compact
        end

        ::Redis.new(redis_options)
      rescue ::Redis::CannotConnectError, ::Redis::ConnectionError => e
        raise Faye::Redis::Connection::ConnectionError, "Failed to connect to Redis: #{e.message}"
      end

      def with_retry(max_attempts = nil, &block)
        max_attempts ||= @options[:max_retries] || 3
        retry_delay = @options[:retry_delay] || 1
        attempts = 0

        begin
          yield
        rescue ::Redis::ConnectionError, ::Redis::TimeoutError, EOFError => e
          attempts += 1
          if attempts < max_attempts
            sleep(retry_delay * (2 ** (attempts - 1))) # Exponential backoff
            retry
          else
            raise Faye::Redis::Connection::ConnectionError, "Redis operation failed after #{max_attempts} attempts: #{e.message}"
          end
        end
      end

      def namespace_key(key)
        namespace = @options[:namespace] || 'faye'
        "#{namespace}:#{key}"
      end
    end
  end
end
