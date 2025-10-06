require 'bundler/setup'
require 'rspec'
require 'redis'
require 'eventmachine'
require_relative '../lib/faye-redis-ng'

# Configure RSpec
RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = false

  if config.files_to_run.one?
    config.default_formatter = 'doc'
  end

  config.order = :random
  Kernel.srand config.seed

  # Check Redis availability before suite
  config.before(:suite) do
    begin
      redis = Redis.new(host: 'localhost', port: 6379, timeout: 1)
      redis.ping
      redis.quit
      puts "✅ Redis is available for testing"
    rescue => e
      puts "❌ Redis is not available: #{e.message}"
      puts "   Please start Redis: docker run -d -p 6379:6379 valkey/valkey:8"
      exit 1
    end
  end

  # Clean up Redis before each test
  config.before(:each) do
    redis = Redis.new(host: 'localhost', port: 6379, db: 15)
    redis.flushdb
    redis.quit
  rescue => e
    skip "Redis not available: #{e.message}"
  end
end

# Helper method to run code in EventMachine
def em_run(timeout = 1, &block)
  EM.run do
    EM.add_timer(timeout) { EM.stop }
    block.call
  end
end

# Test options for Redis connection
def test_redis_options
  {
    host: 'localhost',
    port: 6379,
    database: 15, # Use separate test database
    namespace: 'test',
    log_level: :silent
  }
end
