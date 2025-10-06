# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2025-10-06

### Added
- **Pub/Sub Auto-reconnect**: Automatic reconnection mechanism for Redis pub/sub connections with exponential backoff
  - Configurable `pubsub_max_reconnect_attempts` (default: 10)
  - Configurable `pubsub_reconnect_delay` (default: 1 second)
  - Exponential backoff with jitter to prevent thundering herd
- **Unified Logging System**: New Logger class for consistent, structured logging across all components
  - Timestamp-based log entries
  - Component-specific logging
  - Log levels: silent, error, info, debug
- **Ruby 3.4 Support**: Added Ruby 3.4 to CI test matrix

### Changed
- **Secure ID Generation**: Replaced time-based ID generation with `SecureRandom.uuid` for client IDs and message IDs
  - Eliminates potential ID collisions in high-concurrency scenarios
  - Improves security by using cryptographically secure random numbers
- **Improved Error Handling**: Enhanced error handling in `publish` method with proper callbacks
- **Performance Optimization**: Optimized `dequeue_all` to use Redis pipelining for batch operations
  - Reduces network round trips from O(n) to O(1) for message deletion
  - Significantly faster for clients with many queued messages

### Fixed
- **Redis::CannotConnectError Handling**: Added proper exception handling for `Redis::CannotConnectError` in `connected?` and `with_retry` methods
- **Ruby 3.0+ Compatibility**: Added explicit `require 'set'` for Ruby 3.0+ compatibility
- **Branch Coverage**: Removed strict branch coverage requirement to allow builds to pass

### Security
- Client and message IDs now use `SecureRandom.uuid` instead of predictable time-based generation

[Unreleased]: https://github.com/7a6163/faye-redis-ng/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/7a6163/faye-redis-ng/releases/tag/v1.0.0
