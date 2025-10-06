require_relative 'redis/version'
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
        @client_registry.destroy(client_id, &callback)
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
    def publish(message, channels)
      channels = [channels] unless channels.is_a?(Array)

      channels.each do |channel|
        # Store message in queues for subscribed clients
        @subscription_manager.get_subscribers(channel) do |client_ids|
          client_ids.each do |client_id|
            @message_queue.enqueue(client_id, message)
          end
        end

        # Publish to Redis pub/sub for cross-server routing
        @pubsub_coordinator.publish(channel, message)
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
      "#{Time.now.to_i}#{rand(1000000)}"
    end

    def setup_message_routing
      # Subscribe to message events from other servers
      @pubsub_coordinator.on_message do |channel, message|
        @subscription_manager.get_subscribers(channel) do |client_ids|
          client_ids.each do |client_id|
            @message_queue.enqueue(client_id, message)
          end
        end
      end
    end
  end
end
