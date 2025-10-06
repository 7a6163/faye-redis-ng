require 'spec_helper'

RSpec.describe Faye::Redis::MessageQueue do
  let(:connection) { Faye::Redis::Connection.new(test_redis_options) }
  let(:queue) { described_class.new(connection, test_redis_options) }
  let(:message) do
    {
      'channel' => '/messages',
      'data' => { 'text' => 'Hello, World!' },
      'clientId' => 'sender-123'
    }
  end

  after do
    connection.disconnect
  end

  describe '#enqueue' do
    it 'enqueues a message for a client' do
      em_run do
        queue.enqueue('client-1', message) do |success|
          expect(success).to be true
          EM.stop
        end
      end
    end

    it 'generates UUID format message IDs' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.dequeue_all('client-1') do |messages|
            message_id = messages.first['id']
            uuid_pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
            expect(message_id).to match(uuid_pattern)
            EM.stop
          end
        end
      end
    end

    it 'generates unique message IDs' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.enqueue('client-1', message) do
            queue.enqueue('client-1', message) do
              queue.dequeue_all('client-1') do |messages|
                ids = messages.map { |m| m['id'] }
                expect(ids.uniq.length).to eq(3)
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'stores message data' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.size('client-1') do |size|
            expect(size).to eq(1)
            EM.stop
          end
        end
      end
    end

    it 'handles enqueue errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        queue.enqueue('client-1', message) do |success|
          expect(success).to be false
          EM.stop
        end
      end
    end
  end

  describe '#dequeue_all' do
    it 'dequeues all messages for a client' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.dequeue_all('client-1') do |messages|
            expect(messages.size).to eq(1)
            expect(messages.first['channel']).to eq('/messages')
            expect(messages.first['data']).to eq({ 'text' => 'Hello, World!' })
            EM.stop
          end
        end
      end
    end

    it 'efficiently dequeues multiple messages using pipeline' do
      em_run do
        # Enqueue multiple messages
        queue.enqueue('client-1', message) do
          queue.enqueue('client-1', message) do
            queue.enqueue('client-1', message) do
              queue.enqueue('client-1', message) do
                queue.enqueue('client-1', message) do
                  # Dequeue all at once
                  queue.dequeue_all('client-1') do |messages|
                    expect(messages.size).to eq(5)
                    EM.stop
                  end
                end
              end
            end
          end
        end
      end
    end

    it 'clears the queue after dequeueing' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.dequeue_all('client-1') do
            queue.size('client-1') do |size|
              expect(size).to eq(0)
              EM.stop
            end
          end
        end
      end
    end

    it 'returns empty array for empty queue' do
      em_run do
        queue.dequeue_all('client-1') do |messages|
          expect(messages).to eq([])
          EM.stop
        end
      end
    end

    it 'handles dequeue errors gracefully' do
      em_run do
        queue.enqueue('client-1', message) do
          # Disconnect to cause error
          connection.disconnect

          queue.dequeue_all('client-1') do |messages|
            expect(messages).to eq([])
            EM.stop
          end
        end
      end
    end

    it 'handles JSON parse errors in message data' do
      em_run do
        # Manually insert malformed data to test error handling
        connection_new = Faye::Redis::Connection.new(test_redis_options)

        connection_new.with_redis do |redis|
          redis.rpush('test:messages:client-1', 'bad-message-id')
          redis.hset('test:message:bad-message-id', 'data', 'invalid json')
        end

        queue.dequeue_all('client-1') do |messages|
          # Should handle parse error gracefully
          connection_new.disconnect
          EM.stop
        end
      end
    end
  end

  describe '#peek' do
    it 'returns messages without removing them' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.peek('client-1') do |messages|
            expect(messages.size).to eq(1)

            queue.size('client-1') do |size|
              expect(size).to eq(1) # Still in queue
              EM.stop
            end
          end
        end
      end
    end

    it 'limits number of messages returned' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.enqueue('client-1', message) do
            queue.enqueue('client-1', message) do
              queue.peek('client-1', 2) do |messages|
                expect(messages.size).to eq(2)
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe '#size' do
    it 'returns queue size' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.enqueue('client-1', message) do
            queue.size('client-1') do |size|
              expect(size).to eq(2)
              EM.stop
            end
          end
        end
      end
    end

    it 'returns 0 for empty queue' do
      em_run do
        queue.size('client-1') do |size|
          expect(size).to eq(0)
          EM.stop
        end
      end
    end
  end

  describe '#clear' do
    it 'clears all messages from queue' do
      em_run do
        queue.enqueue('client-1', message) do
          queue.enqueue('client-1', message) do
            queue.clear('client-1') do |success|
              expect(success).to be true

              queue.size('client-1') do |size|
                expect(size).to eq(0)
                EM.stop
              end
            end
          end
        end
      end
    end
  end

  describe 'message ordering' do
    it 'maintains FIFO order' do
      message1 = message.merge('data' => { 'text' => 'First' })
      message2 = message.merge('data' => { 'text' => 'Second' })
      message3 = message.merge('data' => { 'text' => 'Third' })

      em_run do
        queue.enqueue('client-1', message1) do
          queue.enqueue('client-1', message2) do
            queue.enqueue('client-1', message3) do
              queue.dequeue_all('client-1') do |messages|
                expect(messages[0]['data']['text']).to eq('First')
                expect(messages[1]['data']['text']).to eq('Second')
                expect(messages[2]['data']['text']).to eq('Third')
                EM.stop
              end
            end
          end
        end
      end
    end
  end
end
