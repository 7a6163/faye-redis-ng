require 'securerandom'
require_relative 'redis/version'
require_relative 'redis/logger'
require_relative 'redis/connection'
require_relative 'redis/client_registry'
require_relative 'redis/subscription_manager'
require_relative 'redis/message_queue'
require_relative 'redis/pubsub_coordinator'

module Faye
  class Redis
    # Default configuration options
    DEFAULT_OPTIONS = {
      host: 'localhost',
      port: 6379,
      database: 0,
      password: nil,
      pool_size: 5,
      pool_timeout: 5,
      connect_timeout: 1,
      read_timeout: 1,
      write_timeout: 1,
      max_retries: 3,
      retry_delay: 1,
      client_timeout: 60,
      message_ttl: 3600,
      namespace: 'faye'
    }.freeze

    attr_reader :server, :options, :connection, :client_registry,
                :subscription_manager, :message_queue, :pubsub_coordinator

    # Factory method to create a new Redis engine instance
    def self.create(server, options)
      new(server, options)
    end

    def initialize(server, options = {})
      @server = server
      @options = DEFAULT_OPTIONS.merge(options)
      @logger = Logger.new('Faye::Redis', @options)

      # Initialize components
      @connection = Connection.new(@options)
      @client_registry = ClientRegistry.new(@connection, @options)
      @subscription_manager = SubscriptionManager.new(@connection, @options)
      @message_queue = MessageQueue.new(@connection, @options)
      @pubsub_coordinator = PubSubCoordinator.new(@connection, @options)

      # Set up message routing
      setup_message_routing
    end

    # Create a new client
    def create_client(&callback)
      client_id = generate_client_id
      @client_registry.create(client_id) do |success|
        if success
          callback.call(client_id)
        else
          callback.call(nil)
        end
      end
    end

    # Destroy a client
    def destroy_client(client_id, &callback)
      @subscription_manager.unsubscribe_all(client_id) do
        @message_queue.clear(client_id) do
          @client_registry.destroy(client_id, &callback)
        end
      end
    end

    # Check if a client exists
    def client_exists(client_id, &callback)
      @client_registry.exists?(client_id, &callback)
    end

    # Ping a client to keep it alive
    def ping(client_id)
      @client_registry.ping(client_id)
    end

    # Subscribe a client to a channel
    def subscribe(client_id, channel, &callback)
      @subscription_manager.subscribe(client_id, channel, &callback)
    end

    # Unsubscribe a client from a channel
    def unsubscribe(client_id, channel, &callback)
      @subscription_manager.unsubscribe(client_id, channel, &callback)
    end

    # Publish a message to channels
    def publish(message, channels, &callback)
      channels = [channels] unless channels.is_a?(Array)

      begin
        remaining_operations = channels.size
        success = true

        channels.each do |channel|
          # Get subscribers and process in parallel
          @subscription_manager.get_subscribers(channel) do |client_ids|
            # Immediately publish to pub/sub (don't wait for enqueue)
            @pubsub_coordinator.publish(channel, message) do |published|
              success &&= published
            end

            # Enqueue for all subscribed clients in parallel (batch operation)
            if client_ids.any?
              enqueue_messages_batch(client_ids, message) do |enqueued|
                success &&= enqueued
              end
            end

            # Track completion
            remaining_operations -= 1
            if remaining_operations == 0 && callback
              EventMachine.next_tick { callback.call(success) }
            end
          end
        end
      rescue => e
        log_error("Failed to publish message to channels #{channels}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end
    end

    # Empty a client's message queue
    def empty_queue(client_id)
      @message_queue.dequeue_all(client_id)
    end

    # Disconnect the engine
    def disconnect
      @pubsub_coordinator.disconnect
      @connection.disconnect
    end

    private

    def generate_client_id
      SecureRandom.uuid
    end

    # Batch enqueue messages to multiple clients using a single Redis pipeline
    def enqueue_messages_batch(client_ids, message, &callback)
      return EventMachine.next_tick { callback.call(true) } if client_ids.empty? || !callback

      message_json = message.to_json
      message_ttl = @options[:message_ttl] || 3600
      namespace = @options[:namespace] || 'faye'

      begin
        @connection.with_redis do |redis|
          redis.pipelined do |pipeline|
            client_ids.each do |client_id|
              queue_key = "#{namespace}:messages:#{client_id}"
              pipeline.rpush(queue_key, message_json)
              pipeline.expire(queue_key, message_ttl)
            end
          end
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to batch enqueue messages: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end
    end

    def setup_message_routing
      # Subscribe to message events from other servers
      @pubsub_coordinator.on_message do |channel, message|
        @subscription_manager.get_subscribers(channel) do |client_ids|
          # Use batch enqueue for better performance
          enqueue_messages_batch(client_ids, message) if client_ids.any?
        end
      end
    end

    def log_error(message)
      @logger.error(message)
    end
  end
end
