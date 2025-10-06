# 測試說明

完整的測試套件，涵蓋所有核心組件和集成場景。

## 📋 測試類型

### 🔷 單元測試（Unit Tests）
- **無需 Redis**: 使用 `mock_redis` 進行測試
- **快速執行**: 完全在內存中運行
- **隔離測試**: 不依賴外部服務

### 🔶 集成測試（Integration Tests）
- **需要 Redis**: 測試真實的跨服務器場景
- **標記為 `:integration`**: 可選擇性運行
- **真實環境**: 驗證實際 Redis 操作

## 🚀 運行測試

### 快速開始（無需 Redis）

```bash
# 安裝依賴
bundle install

# 運行單元測試（無需 Redis！）
bundle exec rspec --tag ~integration

# 或使用 rake
rake unit
```

### 完整測試（包含集成測試）

```bash
# 1. 啟動 Redis
redis-server

# 2. 運行所有測試
bundle exec rspec

# 或分別運行
rake unit         # 單元測試
rake integration  # 集成測試
rake spec         # 全部測試
```

## 📁 測試結構

```
spec/
├── spec_helper.rb              # 完整測試配置
├── unit_spec_helper.rb         # 單元測試配置（輕量級）
├── support/
│   └── redis_helpers.rb        # Redis 測試輔助工具
├── faye/
│   ├── redis_spec.rb           # 主引擎測試
│   └── redis/
│       ├── connection_spec.rb          # 連接管理器
│       ├── client_registry_spec.rb     # 客戶端註冊表
│       ├── subscription_manager_spec.rb # 訂閱管理器
│       └── message_queue_spec.rb       # 消息隊列
└── integration/
    └── multi_server_spec.rb    # 多服務器集成測試 ⚠️ 需要 Redis
```

## 🎯 測試標記

### 單元測試（默認）
```ruby
RSpec.describe Faye::Redis::Connection do
  # 自動使用 mock Redis
end
```

### 集成測試
```ruby
RSpec.describe 'Multi-server', :integration do
  # 使用真實 Redis
end
```

## 📊 運行特定測試

```bash
# 只運行單元測試（無需 Redis）
bundle exec rspec --tag ~integration

# 只運行集成測試（需要 Redis）
bundle exec rspec --tag integration

# 運行特定文件
bundle exec rspec spec/faye/redis/connection_spec.rb

# 詳細輸出
bundle exec rspec --format documentation
```

## 🔧 Mock vs Real Redis

### Mock Redis（單元測試）
```ruby
# spec/faye/redis/connection_spec.rb
RSpec.describe Faye::Redis::Connection do
  # ✅ 自動使用 MockRedis
  # ✅ 無需啟動 Redis
  # ✅ 速度快
  # ✅ 隔離測試
end
```

### Real Redis（集成測試）
```ruby
# spec/integration/multi_server_spec.rb
RSpec.describe 'Multi-server', :integration do
  # ⚠️ 需要真實 Redis
  # ✅ 測試真實場景
  # ✅ 驗證跨服務器功能
end
```

## 🛠 Rake 任務

```bash
rake unit           # 單元測試（無需 Redis）
rake integration    # 集成測試（需要 Redis）
rake spec           # 所有測試
rake check_redis    # 檢查 Redis 是否運行
rake setup_test_db  # 清理測試數據庫
rake lint           # 代碼檢查
```

## 🐛 故障排除

### 單元測試失敗

單元測試使用 mock Redis，不應該失敗。如果失敗：

```bash
# 確保安裝了 mock_redis
bundle install

# 檢查 mock_redis 版本
bundle list | grep mock_redis
```

### 集成測試失敗

集成測試需要真實 Redis：

```bash
# 檢查 Redis
redis-cli ping

# 如果未運行，啟動 Redis
redis-server

# 或跳過集成測試
bundle exec rspec --tag ~integration
```

### CI/CD 環境

在 CI 環境中只運行單元測試：

```bash
# GitHub Actions, CircleCI, etc.
bundle exec rspec --tag ~integration
```

或配置 Redis 服務（見 `.github/workflows/test.yml`）

## 📈 持續集成

### GitHub Actions

項目包含 `.github/workflows/test.yml`：

- **單元測試**: 多個 Ruby 版本，無需 Redis
- **集成測試**: Ruby 3.2，使用 Redis 服務

```yaml
# 單元測試 job - 無需 Redis
test:
  run: bundle exec rspec --tag ~integration

# 集成測試 job - 使用 Redis service
integration-test:
  services:
    redis:
      image: redis:7
```

## 🎨 測試覆蓋範圍

### 單元測試覆蓋
- ✅ Connection - 連接池、重試機制
- ✅ ClientRegistry - CRUD 操作
- ✅ SubscriptionManager - 訂閱、通配符
- ✅ MessageQueue - FIFO 隊列
- ✅ Redis Engine - 完整 API

### 集成測試覆蓋
- ✅ 跨服務器消息路由
- ✅ 客戶端狀態共享
- ✅ 訂閱狀態同步
- ✅ Pub/Sub 協調

## 💡 最佳實踐

1. **開發時**: 運行單元測試（快速反饋）
   ```bash
   rake unit
   ```

2. **提交前**: 運行所有測試
   ```bash
   rake spec
   ```

3. **CI/CD**: 單元測試總是運行，集成測試可選

4. **隔離環境**: 集成測試使用獨立數據庫（DB 15）

## 📚 相關資源

- [RSpec 文檔](https://rspec.info/)
- [MockRedis GitHub](https://github.com/sds/mock_redis)
- [EventMachine 指南](https://github.com/eventmachine/eventmachine/wiki)
