require 'json'
require 'set'

module Faye
  class Redis
    class PubSubCoordinator
      attr_reader :connection, :options

      def initialize(connection, options = {})
        @connection = connection
        @options = options
        @subscribers = []
        @redis_subscriber = nil
        @subscribed_channels = Set.new
        @subscriber_thread = nil
        @stop_subscriber = false
        @reconnect_attempts = 0
        # Don't setup subscriber immediately - wait until first publish/subscribe
      end

      # Publish a message to a channel
      def publish(channel, message, &callback)
        # Ensure subscriber is setup
        setup_subscriber unless @subscriber_thread

        message_json = message.to_json

        @connection.with_redis do |redis|
          redis.publish(pubsub_channel(channel), message_json)
        end

        EventMachine.next_tick { callback.call(true) } if callback
      rescue => e
        log_error("Failed to publish message to #{channel}: #{e.message}")
        EventMachine.next_tick { callback.call(false) } if callback
      end

      # Subscribe to messages from other servers
      def on_message(&block)
        @subscribers << block
      end

      # Subscribe to a Redis pub/sub channel
      def subscribe_to_channel(channel)
        return if @subscribed_channels.include?(channel)

        @subscribed_channels.add(channel)

        if @redis_subscriber
          @redis_subscriber.subscribe(pubsub_channel(channel))
        end
      rescue => e
        log_error("Failed to subscribe to channel #{channel}: #{e.message}")
      end

      # Unsubscribe from a Redis pub/sub channel
      def unsubscribe_from_channel(channel)
        return unless @subscribed_channels.include?(channel)

        @subscribed_channels.delete(channel)

        if @redis_subscriber
          @redis_subscriber.unsubscribe(pubsub_channel(channel))
        end
      rescue => e
        log_error("Failed to unsubscribe from channel #{channel}: #{e.message}")
      end

      # Disconnect the pub/sub connection
      def disconnect
        @stop_subscriber = true

        if @subscriber_thread
          @subscriber_thread.kill
          @subscriber_thread = nil
        end

        if @redis_subscriber
          begin
            @redis_subscriber.quit
          rescue => e
            # Ignore errors during disconnect
          end
          @redis_subscriber = nil
        end
        @subscribed_channels.clear
        @subscribers.clear
      end

      private

      def setup_subscriber
        return if @subscriber_thread&.alive?

        @stop_subscriber = false
        @subscriber_thread = Thread.new do
          run_subscriber_loop
        end
      rescue => e
        log_error("Failed to setup pub/sub subscriber: #{e.message}")
      end

      def run_subscriber_loop
        max_reconnect_attempts = @options[:pubsub_max_reconnect_attempts] || 10
        base_delay = @options[:pubsub_reconnect_delay] || 1

        loop do
          break if @stop_subscriber

          begin
            # Create a dedicated Redis connection for pub/sub
            @redis_subscriber = @connection.create_pubsub_connection

            # Subscribe to a wildcard pattern to catch all Faye messages
            pattern = pubsub_channel('*')

            log_info("Starting pub/sub subscriber (attempt #{@reconnect_attempts + 1})")

            @redis_subscriber.psubscribe(pattern) do |on|
              on.pmessage do |pattern_match, channel, message|
                handle_message(channel, message)
              end

              on.psubscribe do |channel, subscriptions|
                log_info("Subscribed to pattern: #{channel}")
                @reconnect_attempts = 0 # Reset on successful subscription
              end

              on.punsubscribe do |channel, subscriptions|
                log_info("Unsubscribed from pattern: #{channel}")
              end
            end
          rescue => e
            break if @stop_subscriber

            @reconnect_attempts += 1
            log_error("Pub/sub subscriber error: #{e.message} (attempt #{@reconnect_attempts})")

            # Clean up failed connection
            begin
              @redis_subscriber&.quit
            rescue
              # Ignore cleanup errors
            end
            @redis_subscriber = nil

            if @reconnect_attempts >= max_reconnect_attempts
              log_error("Max reconnect attempts (#{max_reconnect_attempts}) reached, stopping pub/sub subscriber")
              break
            end

            # Exponential backoff with jitter
            delay = [base_delay * (2 ** (@reconnect_attempts - 1)), 60].min
            jitter = rand * 0.3 * delay
            sleep(delay + jitter)

            log_info("Attempting to reconnect pub/sub subscriber...")
          end
        end
      end

      def handle_message(redis_channel, message_json)
        # Extract the Faye channel from the Redis channel
        channel = extract_channel(redis_channel)

        begin
          message = JSON.parse(message_json)

          # Notify all subscribers
          # Use EventMachine.schedule to safely call from non-EM thread
          # (handle_message is called from subscriber_thread, not EM reactor thread)
          if EventMachine.reactor_running?
            EventMachine.schedule do
              @subscribers.dup.each do |subscriber|
                begin
                  subscriber.call(channel, message)
                rescue => e
                  log_error("Subscriber callback error for #{channel}: #{e.message}")
                end
              end
            end
          else
            log_error("Cannot handle message: EventMachine reactor not running")
          end
        rescue JSON::ParserError => e
          log_error("Failed to parse message from #{channel}: #{e.message}")
        end
      rescue => e
        log_error("Failed to handle message from #{redis_channel}: #{e.message}")
      end

      def pubsub_channel(channel)
        namespace_key("publish:#{channel}")
      end

      def extract_channel(redis_channel)
        # Remove the namespace prefix and 'publish:' prefix
        namespace = @options[:namespace] || 'faye'
        prefix = "#{namespace}:publish:"
        redis_channel.sub(/^#{Regexp.escape(prefix)}/, '')
      end

      def namespace_key(key)
        namespace = @options[:namespace] || 'faye'
        "#{namespace}:#{key}"
      end

      def log_error(message)
        puts "[Faye::Redis::PubSubCoordinator] ERROR: #{message}" if @options[:log_level] != :silent
      end

      def log_info(message)
        puts "[Faye::Redis::PubSubCoordinator] INFO: #{message}" if @options[:log_level] == :debug
      end
    end
  end
end
