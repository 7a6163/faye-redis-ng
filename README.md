# faye-redis-ng

[![Tests](https://github.com/7a6163/faye-redis-ng/actions/workflows/test.yml/badge.svg)](https://github.com/7a6163/faye-redis-ng/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/7a6163/faye-redis-ng/branch/main/graph/badge.svg)](https://codecov.io/gh/7a6163/faye-redis-ng)

A Redis-based backend engine for [Faye](https://faye.jcoglan.com/) messaging server, enabling distribution across multiple web servers.

## Features

- 🚀 **Scalable**: Distribute Faye across multiple server instances
- 🔄 **Real-time synchronization**: Messages are routed between servers via Redis
- 💪 **Reliable**: Built-in connection pooling and retry mechanisms
- 🔒 **Secure**: Support for Redis authentication and SSL/TLS
- 📊 **Observable**: Comprehensive logging and error handling

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'faye-redis-ng'
```

And then execute:

```bash
bundle install
```

Or install it yourself:

```bash
gem install faye-redis-ng
```

## Usage

### Basic Setup

```ruby
require 'faye'
require 'faye-redis-ng'

# Create a Faye server with Redis backend
bayeux = Faye::RackAdapter.new(app, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'localhost',
    port: 6379,
    database: 0
  }
})
```

### Configuration Options

```ruby
{
  # Redis connection
  host: 'localhost',          # Redis server host
  port: 6379,                 # Redis server port
  database: 0,                # Redis database number
  password: nil,              # Redis password (optional)

  # Connection pool
  pool_size: 5,               # Connection pool size
  pool_timeout: 5,            # Pool checkout timeout (seconds)

  # Timeouts
  connect_timeout: 1,         # Connection timeout (seconds)
  read_timeout: 1,            # Read timeout (seconds)
  write_timeout: 1,           # Write timeout (seconds)

  # Retry configuration
  max_retries: 3,             # Max retry attempts
  retry_delay: 1,             # Initial retry delay (seconds)

  # Data expiration
  client_timeout: 60,         # Client session timeout (seconds)
  message_ttl: 3600,          # Message TTL (seconds)
  subscription_ttl: 3600,     # Subscription keys TTL (seconds, default: 1 hour)

  # Garbage collection
  gc_interval: 60,            # Automatic GC interval (seconds), set to 0 or false to disable

  # Logging
  log_level: :info,           # Log level (:silent, :info, :debug)

  # Namespace
  namespace: 'faye'           # Redis key namespace
}
```

### Advanced Configuration

#### With Authentication

```ruby
engine: {
  type: Faye::Redis,
  host: 'redis.example.com',
  port: 6379,
  password: 'your-redis-password'
}
```

#### With SSL/TLS

```ruby
engine: {
  type: Faye::Redis,
  host: 'redis.example.com',
  port: 6380,
  ssl: {
    enabled: true,
    cert_file: '/path/to/cert.pem',
    key_file: '/path/to/key.pem',
    ca_file: '/path/to/ca.pem'
  }
}
```

#### Custom Namespace

```ruby
engine: {
  type: Faye::Redis,
  host: 'localhost',
  port: 6379,
  namespace: 'my-app'  # All Redis keys will be prefixed with 'my-app:'
}
```

## Multi-Server Setup

To run Faye across multiple servers, simply configure each server with the same Redis backend:

### Server 1 (config.ru)

```ruby
require 'faye'
require 'faye-redis-ng'

bayeux = Faye::RackAdapter.new(app, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'redis.example.com',
    port: 6379
  }
})

run bayeux
```

### Server 2 (config.ru)

```ruby
# Same configuration as Server 1
require 'faye'
require 'faye-redis-ng'

bayeux = Faye::RackAdapter.new(app, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'redis.example.com',  # Same Redis server
    port: 6379
  }
})

run bayeux
```

Now clients can connect to either server and messages will be routed correctly between them!

## Architecture

faye-redis-ng uses the following Redis data structures:

- **Client Registry**: Hash and Set for tracking active clients
- **Subscriptions**: Sets for managing channel subscriptions
- **Message Queue**: Lists for queuing messages per client
- **Pub/Sub**: Redis Pub/Sub for cross-server message routing

### Key Components

1. **Connection Manager**: Handles Redis connection pooling and retries
2. **Client Registry**: Manages client lifecycle and sessions
3. **Subscription Manager**: Handles channel subscriptions with wildcard support
4. **Message Queue**: Manages message queuing and delivery
5. **Pub/Sub Coordinator**: Routes messages between server instances

## Development

### Running Tests

```bash
bundle exec rspec
```

### Building the Gem

```bash
gem build faye-redis-ng.gemspec
```

### Installing Locally

```bash
gem install ./faye-redis-ng-0.1.0.gem
```

### Releasing to RubyGems

This project uses GitHub Actions for automated releases. To publish a new version:

1. Update the version in `lib/faye/redis/version.rb`
2. Commit the version change
3. Create and push a git tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The CI/CD pipeline will automatically:
- Run all tests across multiple Ruby versions
- Build the gem
- Publish to RubyGems (requires `RUBYGEMS_API_KEY` secret)
- Create a GitHub release with the gem attached

**Prerequisites:**
- Add `RUBYGEMS_API_KEY` to GitHub repository secrets
- The tag must start with 'v' (e.g., v0.1.0, v1.2.3)

## Memory Management

### Automatic Garbage Collection

**New in v1.0.6**: faye-redis-ng now includes automatic garbage collection that runs every 60 seconds by default. This automatically cleans up expired clients and orphaned subscription keys, preventing memory leaks without any manual intervention.

```ruby
bayeux = Faye::RackAdapter.new(app, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'localhost',
    port: 6379,
    gc_interval: 60  # Run GC every 60 seconds (default)
  }
})
```

To customize the GC interval or disable it:

```ruby
engine: {
  type: Faye::Redis,
  host: 'localhost',
  port: 6379,
  gc_interval: 300  # Run GC every 5 minutes
}

# Or disable automatic GC
engine: {
  type: Faye::Redis,
  host: 'localhost',
  port: 6379,
  gc_interval: 0  # Disabled - you'll need to call cleanup_expired manually
}
```

### Manual Cleanup

If you've disabled automatic GC, you can manually clean up expired clients:

```ruby
# Get the engine instance
engine = bayeux.get_engine

# Clean up expired clients and orphaned data
engine.cleanup_expired do |expired_count|
  puts "Cleaned up #{expired_count} expired clients"
end
```

#### Custom GC Schedule (Optional)

If you need more control, you can disable automatic GC and implement your own schedule:

```ruby
require 'eventmachine'
require 'faye'
require 'faye-redis-ng'

bayeux = Faye::RackAdapter.new(app, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'localhost',
    port: 6379,
    namespace: 'my-app',
    gc_interval: 0  # Disable automatic GC
  }
})

# Custom cleanup schedule - every 5 minutes
EM.add_periodic_timer(300) do
  bayeux.get_engine.cleanup_expired do |count|
    puts "[#{Time.now}] Cleaned up #{count} expired clients" if count > 0
  end
end

run bayeux
```

#### Using Rake Task

Create a Rake task for manual or scheduled cleanup:

```ruby
# lib/tasks/faye_cleanup.rake
namespace :faye do
  desc "Clean up expired Faye clients and orphaned subscriptions"
  task cleanup: :environment do
    require 'eventmachine'

    EM.run do
      engine = Faye::Redis.new(
        nil,
        host: ENV['REDIS_HOST'] || 'localhost',
        port: ENV['REDIS_PORT']&.to_i || 6379,
        namespace: 'my-app'
      )

      engine.cleanup_expired do |count|
        puts "✅ Cleaned up #{count} expired clients"
        engine.disconnect
        EM.stop
      end
    end
  end
end
```

Then schedule it with cron:

```bash
# Run cleanup every hour
0 * * * * cd /path/to/app && bundle exec rake faye:cleanup
```

### What Gets Cleaned Up

The `cleanup_expired` method removes:

1. **Expired client keys** (`clients:{client_id}`)
2. **Orphaned subscription lists** (`subscriptions:{client_id}`)
3. **Orphaned subscription metadata** (`subscription:{client_id}:{channel}`)
4. **Stale client IDs from channel subscribers** (`channels:{channel}`)
5. **Orphaned message queues** (`messages:{client_id}`)

### Memory Leak Prevention

**v1.0.6+**: Automatic garbage collection is now enabled by default, preventing memory leaks from orphaned keys without any configuration needed.

Without GC, abnormal client disconnections (crashes, network failures, etc.) can cause orphaned keys to accumulate:

- **Before v1.0.5**: 10,000 orphaned clients × 5 channels = 50,000+ keys = 100-500 MB leaked
- **v1.0.5**: Manual cleanup required via `cleanup_expired` method
- **v1.0.6+**: Automatic GC runs every 60 seconds by default - no manual intervention needed

The automatic GC ensures memory usage remains stable even with frequent client disconnections.

## Troubleshooting

### Connection Issues

If you're experiencing connection issues:

1. Verify Redis is running: `redis-cli ping`
2. Check Redis connection settings
3. Ensure firewall allows Redis port (default 6379)
4. Check logs for detailed error messages

### Message Delivery Issues

If messages aren't being delivered:

1. Verify all servers use the same Redis instance
2. Check that clients are subscribed to the correct channels
3. Ensure Redis pub/sub is working: `redis-cli PUBSUB CHANNELS`

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

MIT License - see LICENSE file for details

## Acknowledgments

- Built for the [Faye](https://faye.jcoglan.com/) messaging system
- Inspired by the original [faye-redis](https://github.com/faye/faye-redis-ruby) gem
