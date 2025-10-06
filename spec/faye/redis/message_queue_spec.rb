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
