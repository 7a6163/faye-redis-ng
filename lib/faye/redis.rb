require 'securerandom'
require 'set'
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
      namespace: 'faye',
      gc_interval: 60  # Automatic garbage collection interval (seconds), set to 0 or false to disable
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

      # Start automatic garbage collection timer
      start_gc_timer
    end

    # Create a new client
    def create_client(&callback)
      # Ensure GC timer is started (lazy initialization)
      ensure_gc_timer_started

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
        # Ensure message has an ID for deduplication
        message = message.dup unless message.frozen?
        message['id'] ||= generate_message_id

        # Track this message as locally published
        if @local_message_ids
          if @local_message_ids_mutex
            @local_message_ids_mutex.synchronize { @local_message_ids.add(message['id']) }
          else
            @local_message_ids.add(message['id'])
          end
        end

        total_channels = channels.size
        completed_channels = 0
        callback_called = false
        all_success = true

        channels.each do |channel|
          # Get subscribers and process in parallel
          @subscription_manager.get_subscribers(channel) do |client_ids|
            # Track operations for this channel
            pending_ops = 2  # pubsub + enqueue
            channel_success = true
            ops_completed = 0

            complete_channel = lambda do
              ops_completed += 1
              if ops_completed == pending_ops
                # This channel is complete
                all_success &&= channel_success
                completed_channels += 1

                # Call final callback when all channels are done
                if completed_channels == total_channels && !callback_called && callback
                  callback_called = true
                  EventMachine.next_tick { callback.call(all_success) }
                end
              end
            end

            # Publish to pub/sub
            @pubsub_coordinator.publish(channel, message) do |published|
              channel_success &&= published
              complete_channel.call
            end

            # Enqueue for all subscribed clients
            if client_ids.any?
              enqueue_messages_batch(client_ids, message) do |enqueued|
                channel_success &&= enqueued
                complete_channel.call
              end
            else
              # No clients, but still need to complete
              complete_channel.call
            end
          end
        end
      rescue => e
        log_error("Failed to publish message to channels #{channels}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback && !callback_called
      end
    end

    # Empty a client's message queue
    def empty_queue(client_id)
      @message_queue.dequeue_all(client_id)
    end

    # Disconnect the engine
    def disconnect
      # Stop GC timer if running
      stop_gc_timer

      @pubsub_coordinator.disconnect
      @connection.disconnect
    end

    # Clean up expired clients and their associated data
    def cleanup_expired(&callback)
      @client_registry.cleanup_expired do |expired_count|
        @logger.info("Cleaned up #{expired_count} expired clients") if expired_count > 0

        # Always clean up orphaned subscription keys (even if no expired clients)
        # This handles cases where subscriptions were orphaned due to crashes
        cleanup_orphaned_subscriptions do
          callback.call(expired_count) if callback
        end
      end
    end

    private

    def generate_client_id
      SecureRandom.uuid
    end

    def generate_message_id
      SecureRandom.uuid
    end

    # Batch enqueue messages to multiple clients using a single Redis pipeline
    def enqueue_messages_batch(client_ids, message, &callback)
      # Handle empty client list
      if client_ids.empty?
        EventMachine.next_tick { callback.call(true) } if callback
        return
      end

      # No callback provided, but still need to enqueue
      # (setup_message_routing calls this without callback)

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

    def cleanup_orphaned_subscriptions(&callback)
      # Get all active client IDs
      @client_registry.all do |active_clients|
        active_set = active_clients.to_set
        namespace = @options[:namespace] || 'faye'

        # Scan for subscription keys and clean up orphaned ones
        @connection.with_redis do |redis|
          cursor = "0"
          orphaned_keys = []

          loop do
            cursor, keys = redis.scan(cursor, match: "#{namespace}:subscriptions:*", count: 100)

            keys.each do |key|
              # Extract client_id from key (format: namespace:subscriptions:client_id)
              client_id = key.split(':').last
              orphaned_keys << client_id unless active_set.include?(client_id)
            end

            break if cursor == "0"
          end

          # Clean up orphaned subscription data
          if orphaned_keys.any?
            @logger.info("Cleaning up #{orphaned_keys.size} orphaned subscription sets")

            orphaned_keys.each do |client_id|
              # Get channels for this orphaned client
              channels = redis.smembers("#{namespace}:subscriptions:#{client_id}")

              # Remove in batch
              redis.pipelined do |pipeline|
                # Delete client's subscription list
                pipeline.del("#{namespace}:subscriptions:#{client_id}")

                # Delete each subscription metadata and remove from channel subscribers
                channels.each do |channel|
                  pipeline.del("#{namespace}:subscription:#{client_id}:#{channel}")
                  pipeline.srem("#{namespace}:channels:#{channel}", client_id)
                end

                # Delete message queue if exists
                pipeline.del("#{namespace}:messages:#{client_id}")
              end
            end
          end
        end

        EventMachine.next_tick { callback.call } if callback
      end
    rescue => e
      log_error("Failed to cleanup orphaned subscriptions: #{e.message}")
      EventMachine.next_tick { callback.call } if callback
    end

    def setup_message_routing
      # Track locally published message IDs to avoid duplicate enqueue
      @local_message_ids = Set.new
      @local_message_ids_mutex = Mutex.new if defined?(Mutex)

      # Subscribe to message events from other servers
      @pubsub_coordinator.on_message do |channel, message|
        # Skip if this is a message we just published locally
        # (Redis pub/sub echoes back messages to the publisher)
        message_id = message['id']
        is_local = false

        if message_id
          if @local_message_ids_mutex
            @local_message_ids_mutex.synchronize do
              is_local = @local_message_ids.delete(message_id)
            end
          else
            is_local = @local_message_ids.delete(message_id)
          end
        end

        next if is_local

        # Enqueue for remote servers' messages only
        @subscription_manager.get_subscribers(channel) do |client_ids|
          enqueue_messages_batch(client_ids, message) if client_ids.any?
        end
      end
    end

    def log_error(message)
      @logger.error(message)
    end

    # Start automatic garbage collection timer
    def start_gc_timer
      gc_interval = @options[:gc_interval]

      # Skip if GC is disabled (0, false, or nil)
      return if !gc_interval || gc_interval == 0

      # Only start timer if EventMachine is running
      return unless EventMachine.reactor_running?

      @logger.info("Starting automatic GC timer with interval: #{gc_interval} seconds")

      @gc_timer = EventMachine.add_periodic_timer(gc_interval) do
        @logger.debug("Running automatic garbage collection")
        cleanup_expired do |count|
          @logger.debug("GC completed: #{count} expired clients cleaned") if count > 0
        end
      end
    end

    # Ensure GC timer is started (called lazily on first operation)
    def ensure_gc_timer_started
      return if @gc_timer  # Already started
      return if !@options[:gc_interval] || @options[:gc_interval] == 0  # Disabled

      start_gc_timer
    end

    # Stop automatic garbage collection timer
    def stop_gc_timer
      if @gc_timer
        EventMachine.cancel_timer(@gc_timer)
        @gc_timer = nil
        @logger.info("Stopped automatic GC timer")
      end
    end
  end
end
