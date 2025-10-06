module Faye
  class Redis
    class Logger
      LEVELS = {
        silent: 0,
        error: 1,
        info: 2,
        debug: 3
      }.freeze

      attr_reader :level, :component

      def initialize(component, options = {})
        @component = component
        level_name = options[:log_level] || :info
        @level = LEVELS[level_name] || LEVELS[:info]
      end

      def error(message)
        log(:error, message) if @level >= LEVELS[:error]
      end

      def info(message)
        log(:info, message) if @level >= LEVELS[:info]
      end

      def debug(message)
        log(:debug, message) if @level >= LEVELS[:debug]
      end

      private

      def log(level, message)
        timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
        puts "[#{timestamp}] [#{@component}] #{level.to_s.upcase}: #{message}"
      end
    end
  end
end
