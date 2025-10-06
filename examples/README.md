# Faye Redis NG Examples

This directory contains example applications demonstrating how to use faye-redis-ng.

## 📋 Example List

### 1. Basic Example
**Files:** `config.ru`, `client.html`

The simplest Faye application demonstrating basic publish/subscribe functionality.

**How to run:**
```bash
# 1. Start Redis
redis-server

# 2. Start Faye server
rackup examples/config.ru -p 9292

# 3. Open browser
open http://localhost:9292
```

**Features:**
- ✅ Subscribe to channels
- ✅ Publish messages
- ✅ Real-time message receiving
- ✅ Wildcard subscriptions support (`/messages/*`)

---

### 2. Chat Room Example
**Files:** `chat_server.ru`, `chat_client.html`

A complete chat room application demonstrating multi-room chat functionality.

**How to run:**
```bash
# 1. Start Redis
redis-server

# 2. Start chat server
rackup examples/chat_server.ru -p 9292

# 3. Open browser (can open multiple windows for testing)
open http://localhost:9292
```

**Features:**
- ✅ Multiple chat rooms (general, random, tech)
- ✅ Username display
- ✅ Real-time message synchronization
- ✅ Beautiful UI design
- ✅ Channel authorization control

---

## 🚀 Multi-Server Deployment Testing

Test cross-server message routing:

### Step 1: Start Redis
```bash
redis-server
```

### Step 2: Start first server
```bash
rackup examples/config.ru -p 9292
```

### Step 3: Start second server
```bash
rackup examples/config.ru -p 9293
```

### Step 4: Test
1. Open `http://localhost:9292` in browser
2. Open `http://localhost:9293` in another browser window
3. Subscribe to the same channel in either window (e.g., `/messages`)
4. Send a message from one window
5. Observe that the other window (connected to a different server) also receives the message!

This demonstrates that Redis correctly routes messages between servers.

---

## 🔧 Environment Variable Configuration

You can use environment variables to configure Redis connection:

```bash
export REDIS_HOST=localhost
export REDIS_PORT=6379
export REDIS_DB=0
export REDIS_PASSWORD=your-password

rackup examples/config.ru -p 9292
```

---

## 🎯 Advanced Feature Testing

### Wildcard Subscriptions
```javascript
// Subscribe to all channels under /chat
client.subscribe('/chat/*', callback);

// Subscribe to all levels
client.subscribe('/chat/**', callback);
```

### Channel Patterns
- `/messages` - Single channel
- `/chat/room1` - Room channel
- `/chat/*/private` - Wildcard matching
- `/notifications/**` - Multi-level wildcard

---

## 🐛 Troubleshooting

### Connection Failed
1. Verify Redis is running: `redis-cli ping`
2. Check Redis connection settings
3. Review server logs

### Messages Not Received
1. Confirm subscription to the correct channel
2. Check Redis pub/sub: `redis-cli PUBSUB CHANNELS`
3. Ensure all servers are connected to the same Redis instance

### View Redis Data
```bash
# View all faye-related keys
redis-cli KEYS "faye-example:*"

# Monitor pub/sub activity
redis-cli MONITOR
```

---

## 📝 Custom Examples

You can create your own application based on these examples:

```ruby
require 'faye'
require 'faye-redis-ng'

bayeux = Faye::RackAdapter.new(nil, {
  mount: '/faye',
  timeout: 25,
  engine: {
    type: Faye::Redis,
    host: 'localhost',
    port: 6379,
    namespace: 'my-app',  # Custom namespace
    pool_size: 10,        # Connection pool size
    client_timeout: 120   # Client timeout (seconds)
  }
})

run bayeux
```

---

## 💡 Tips

1. **Development**: Use `log_level: :debug` to see detailed logs
2. **Production**: Use `log_level: :info` or `:silent`
3. **Performance**: Adjust `pool_size` and `client_timeout` parameters
4. **Security**: Use Redis password and SSL/TLS in production

---

## 🔗 More Resources

- [Faye Official Documentation](https://faye.jcoglan.com/)
- [Redis Documentation](https://redis.io/documentation)
- [faye-redis-ng GitHub](https://github.com/7a6163/faye-redis-ng)
