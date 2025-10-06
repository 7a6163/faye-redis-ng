require 'spec_helper'

RSpec.describe Faye::Redis::Connection do
  let(:options) { test_redis_options }
  let(:connection) { described_class.new(options) }

  after do
    connection.disconnect if connection
  end

  describe '#initialize' do
    it 'creates a connection pool' do
      expect(connection).to be_a(Faye::Redis::Connection)
      expect(connection.options).to eq(options)
    end

    it 'uses default pool size if not specified' do
      conn = described_class.new(host: 'localhost')
      expect(conn.options[:pool_size]).to be_nil
    end
  end

  describe '#with_redis' do
    it 'executes a block with a Redis connection' do
      result = connection.with_redis { |redis| redis.ping }
      expect(result).to eq('PONG')
    end

    it 'handles Redis operations' do
      connection.with_redis do |redis|
        redis.set('test:key', 'value')
      end

      result = connection.with_redis do |redis|
        redis.get('test:key')
      end

      expect(result).to eq('value')
    end

    it 'returns connection to pool after use' do
      10.times do
        connection.with_redis { |redis| redis.ping }
      end
      # Should not raise error if pool works correctly
    end
  end

  describe '#connected?' do
    it 'returns true when connected' do
      expect(connection.connected?).to be true
    end

    it 'returns false when connection fails' do
      bad_connection = described_class.new(host: 'invalid-host', port: 9999, connect_timeout: 0.1)
      expect(bad_connection.connected?).to be false
    end
  end

  describe '#ping' do
    it 'pings the Redis server' do
      expect(connection.ping).to eq('PONG')
    end
  end

  describe '#disconnect' do
    it 'closes all connections in the pool' do
      connection.disconnect
      expect { connection.ping }.to raise_error(ConnectionPool::PoolShuttingDownError)
    end
  end

  describe 'retry mechanism' do
    it 'retries failed operations' do
      call_count = 0
      allow_any_instance_of(::Redis).to receive(:ping) do
        call_count += 1
        raise ::Redis::TimeoutError if call_count == 1
        'PONG'
      end

      expect(connection.ping).to eq('PONG')
      expect(call_count).to be >= 2
    end

    it 'retries on CannotConnectError' do
      call_count = 0
      allow_any_instance_of(::Redis).to receive(:ping) do
        call_count += 1
        raise ::Redis::CannotConnectError if call_count == 1
        'PONG'
      end

      expect(connection.ping).to eq('PONG')
      expect(call_count).to be >= 2
    end

    it 'handles CannotConnectError in connected?' do
      bad_connection = described_class.new(
        host: 'nonexistent.invalid',
        port: 9999,
        connect_timeout: 0.1,
        max_retries: 1,
        retry_delay: 0.01
      )
      expect(bad_connection.connected?).to be false
    end

    it 'raises error after max retries' do
      conn = described_class.new(options.merge(max_retries: 2, retry_delay: 0.01))

      allow_any_instance_of(Redis).to receive(:get)
        .and_raise(Redis::TimeoutError)

      expect {
        conn.with_redis { |redis| redis.get('key') }
      }.to raise_error(Faye::Redis::Connection::ConnectionError)
    end

    it 'uses exponential backoff for retries' do
      conn = described_class.new(options.merge(max_retries: 3, retry_delay: 0.1))
      call_count = 0

      allow_any_instance_of(Redis).to receive(:get) do
        call_count += 1
        raise Redis::TimeoutError if call_count < 3
        'success'
      end

      start_time = Time.now
      conn.with_redis { |redis| redis.get('key') }
      elapsed = Time.now - start_time

      # Should have delays: 0.1s, 0.2s = 0.3s total minimum
      expect(elapsed).to be >= 0.3
    end
  end

  describe '#create_pubsub_connection' do
    it 'creates a dedicated pub/sub connection' do
      pubsub = connection.create_pubsub_connection
      expect(pubsub).to be_a(Redis)
      expect(pubsub.ping).to eq('PONG')
      pubsub.quit
    end
  end
end
