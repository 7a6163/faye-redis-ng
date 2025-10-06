require 'faye'
require_relative '../lib/faye-redis-ng'

# Chat application with authentication
class ServerAuth
  def incoming(message, request, callback)
    # Allow subscription and publishing to /chat/** channels
    if message['channel'] !~ %r{^/meta/} && message['channel'] !~ %r{^/chat/}
      message['error'] = 'Invalid channel'
    end
    callback.call(message)
  end
end

bayeux = Faye::RackAdapter.new(nil, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'localhost',
    port: 6379,
    namespace: 'chat-app'
  }
})

bayeux.add_extension(ServerAuth.new)

# Serve chat client
use Rack::Static, urls: ['/'], root: 'examples', index: 'chat_client.html'

run bayeux
