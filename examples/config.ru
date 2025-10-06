require 'faye'
require_relative '../lib/faye-redis-ng'

# Basic Faye server with Redis backend
bayeux = Faye::RackAdapter.new(nil, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: ENV['REDIS_HOST'] || 'localhost',
    port: (ENV['REDIS_PORT'] || 6379).to_i,
    database: (ENV['REDIS_DB'] || 0).to_i,
    password: ENV['REDIS_PASSWORD'],
    namespace: 'faye-example',
    log_level: :info
  }
})

# Simple static file server for the HTML client
use Rack::Static, urls: ['/'], root: 'examples', index: 'client.html'

run bayeux
