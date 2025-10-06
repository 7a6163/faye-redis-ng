# Faye Redis NG Examples

這個目錄包含多個示範應用，展示如何使用 faye-redis-ng。

## 📋 範例列表

### 1. 基本範例 (Basic Example)
**檔案:** `config.ru`, `client.html`

最簡單的 Faye 應用，展示基本的發布/訂閱功能。

**啟動方式:**
```bash
# 1. 啟動 Redis
redis-server

# 2. 啟動 Faye 服務器
rackup examples/config.ru -p 9292

# 3. 開啟瀏覽器
open http://localhost:9292
```

**功能:**
- ✅ 訂閱頻道
- ✅ 發布消息
- ✅ 實時接收消息
- ✅ 支援通配符訂閱 (`/messages/*`)

---

### 2. 聊天室範例 (Chat Room)
**檔案:** `chat_server.ru`, `chat_client.html`

完整的聊天室應用，展示多房間聊天功能。

**啟動方式:**
```bash
# 1. 啟動 Redis
redis-server

# 2. 啟動聊天服務器
rackup examples/chat_server.ru -p 9292

# 3. 開啟瀏覽器（可以開多個視窗測試）
open http://localhost:9292
```

**功能:**
- ✅ 多個聊天室 (general, random, tech)
- ✅ 用戶名稱顯示
- ✅ 實時消息同步
- ✅ 美觀的 UI 設計
- ✅ 頻道授權控制

---

## 🚀 多服務器部署測試

測試跨服務器消息路由：

### 步驟 1: 啟動 Redis
```bash
redis-server
```

### 步驟 2: 啟動第一個服務器
```bash
rackup examples/config.ru -p 9292
```

### 步驟 3: 啟動第二個服務器
```bash
rackup examples/config.ru -p 9293
```

### 步驟 4: 測試
1. 在瀏覽器打開 `http://localhost:9292`
2. 在另一個瀏覽器視窗打開 `http://localhost:9293`
3. 在任一視窗訂閱相同頻道（例如 `/messages`）
4. 在其中一個視窗發送消息
5. 觀察另一個視窗（連接到不同服務器）也能收到消息！

這證明了 Redis 正確地在服務器之間路由消息。

---

## 🔧 環境變數配置

你可以使用環境變數來配置 Redis 連接：

```bash
export REDIS_HOST=localhost
export REDIS_PORT=6379
export REDIS_DB=0
export REDIS_PASSWORD=your-password

rackup examples/config.ru -p 9292
```

---

## 🎯 進階功能測試

### 通配符訂閱
```javascript
// 訂閱所有 /chat 下的頻道
client.subscribe('/chat/*', callback);

// 訂閱所有層級
client.subscribe('/chat/**', callback);
```

### 頻道模式
- `/messages` - 單一頻道
- `/chat/room1` - 房間頻道
- `/chat/*/private` - 通配符匹配
- `/notifications/**` - 多層級通配符

---

## 🐛 故障排除

### 連接失敗
1. 確認 Redis 正在運行: `redis-cli ping`
2. 檢查 Redis 連接設定
3. 查看服務器日誌

### 消息未收到
1. 確認訂閱了正確的頻道
2. 檢查 Redis pub/sub: `redis-cli PUBSUB CHANNELS`
3. 確認所有服務器連接到同一個 Redis 實例

### 查看 Redis 數據
```bash
# 查看所有 faye 相關的 key
redis-cli KEYS "faye-example:*"

# 監控 pub/sub 活動
redis-cli MONITOR
```

---

## 📝 自定義範例

你可以基於這些範例創建自己的應用：

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
    namespace: 'my-app',  # 自定義命名空間
    pool_size: 10,        # 連接池大小
    client_timeout: 120   # 客戶端超時（秒）
  }
})

run bayeux
```

---

## 💡 提示

1. **開發環境**: 使用 `log_level: :debug` 查看詳細日誌
2. **生產環境**: 使用 `log_level: :info` 或 `:silent`
3. **性能優化**: 調整 `pool_size` 和 `client_timeout` 參數
4. **安全性**: 在生產環境中使用 Redis 密碼和 SSL/TLS

---

## 🔗 更多資源

- [Faye 官方文檔](https://faye.jcoglan.com/)
- [Redis 文檔](https://redis.io/documentation)
- [faye-redis-ng GitHub](https://github.com/yourusername/faye-redis-ng)
