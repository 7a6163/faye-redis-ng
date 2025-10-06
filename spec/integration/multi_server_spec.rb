require 'spec_helper'

RSpec.describe 'Multi-server integration' do
  let(:server1) { double('server1') }
  let(:server2) { double('server2') }
  let(:options) { test_redis_options }

  let(:engine1) { Faye::Redis.new(server1, options) }
  let(:engine2) { Faye::Redis.new(server2, options) }

  after do
    engine1.disconnect
    engine2.disconnect
  end

  it 'routes messages between servers' do
    em_run(3) do
      # Create client on server 1
      engine1.create_client do |client1_id|
        engine1.subscribe(client1_id, '/messages') do

          # Create client on server 2
          engine2.create_client do |client2_id|
            engine2.subscribe(client2_id, '/messages') do

              # Publish from server 1
              message = {
                'channel' => '/messages',
                'data' => { 'text' => 'Cross-server message' }
              }

              engine1.publish(message, '/messages')

              # Wait for pub/sub propagation
              EM.add_timer(1) do
                # Check both clients received the message
                engine1.message_queue.size(client1_id) do |size1|
                  engine2.message_queue.size(client2_id) do |size2|
                    expect(size1).to be > 0
                    expect(size2).to be > 0
                    EM.stop
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  it 'shares client state across servers' do
    em_run do
      # Create client on server 1
      engine1.create_client do |client_id|

        # Check client exists on server 2
        engine2.client_exists(client_id) do |exists|
          expect(exists).to be true
          EM.stop
        end
      end
    end
  end

  it 'shares subscription state across servers' do
    em_run do
      # Subscribe on server 1
      engine1.create_client do |client_id|
        engine1.subscribe(client_id, '/messages') do

          # Check subscription visible on server 2
          engine2.subscription_manager.get_subscribers('/messages') do |subscribers|
            expect(subscribers).to include(client_id)
            EM.stop
          end
        end
      end
    end
  end
end
