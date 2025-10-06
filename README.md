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
- Inspired by the original faye-redis gem
