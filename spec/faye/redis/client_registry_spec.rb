require 'spec_helper'

RSpec.describe Faye::Redis::ClientRegistry do
  let(:connection) { Faye::Redis::Connection.new(test_redis_options) }
  let(:registry) { described_class.new(connection, test_redis_options) }

  after do
    connection.disconnect
  end

  describe '#create' do
    it 'creates a new client' do
      em_run do
        registry.create('client-123') do |success|
          expect(success).to be true
          EM.stop
        end
      end
    end

    it 'stores client data in Redis' do
      em_run do
        registry.create('client-123') do
          registry.get('client-123') do |data|
            expect(data).not_to be_nil
            expect(data[:client_id]).to eq('client-123')
            expect(data[:created_at]).to be_a(String)
            EM.stop
          end
        end
      end
    end

    it 'adds client to index' do
      em_run do
        registry.create('client-123') do
          registry.all do |client_ids|
            expect(client_ids).to include('client-123')
            EM.stop
          end
        end
      end
    end
  end

  describe '#destroy' do
    it 'removes a client' do
      em_run do
        registry.create('client-123') do
          registry.destroy('client-123') do |success|
            expect(success).to be true

            registry.exists?('client-123') do |exists|
              expect(exists).to be false
              EM.stop
            end
          end
        end
      end
    end

    it 'removes client from index' do
      em_run do
        registry.create('client-123') do
          registry.destroy('client-123') do
            registry.all do |client_ids|
              expect(client_ids).not_to include('client-123')
              EM.stop
            end
          end
        end
      end
    end
  end

  describe '#exists?' do
    it 'returns true for existing client' do
      em_run do
        registry.create('client-123') do
          registry.exists?('client-123') do |exists|
            expect(exists).to be true
            EM.stop
          end
        end
      end
    end

    it 'returns false for non-existing client' do
      em_run do
        registry.exists?('non-existent') do |exists|
          expect(exists).to be false
          EM.stop
        end
      end
    end
  end

  describe '#ping' do
    it 'updates last_ping timestamp' do
      em_run do
        registry.create('client-123') do
          sleep 1.1  # Wait over 1 second to ensure timestamp changes
          registry.ping('client-123')

          registry.get('client-123') do |data|
            expect(data[:last_ping].to_i).to be > data[:created_at].to_i
            EM.stop
          end
        end
      end
    end
  end

  describe '#get' do
    it 'retrieves client data' do
      em_run do
        registry.create('client-123') do
          registry.get('client-123') do |data|
            expect(data[:client_id]).to eq('client-123')
            expect(data).to have_key(:created_at)
            expect(data).to have_key(:last_ping)
            expect(data).to have_key(:server_id)
            EM.stop
          end
        end
      end
    end

    it 'returns nil for non-existent client' do
      em_run do
        registry.get('non-existent') do |data|
          expect(data).to be_nil
          EM.stop
        end
      end
    end
  end

  describe '#all' do
    it 'returns all client IDs' do
      em_run do
        registry.create('client-1') do
          registry.create('client-2') do
            registry.all do |client_ids|
              expect(client_ids).to contain_exactly('client-1', 'client-2')
              EM.stop
            end
          end
        end
      end
    end

    it 'returns empty array when no clients' do
      em_run do
        registry.all do |client_ids|
          expect(client_ids).to eq([])
          EM.stop
        end
      end
    end
  end

  describe '#cleanup_expired' do
    it 'removes expired clients from index' do
      em_run do
        registry.create('client-1') do
          # Manually remove the client data (simulate expiration)
          connection.with_redis do |redis|
            redis.del('test:clients:client-1')
          end

          # Cleanup should remove from index
          registry.cleanup_expired

          # Give it time to process
          EM.add_timer(0.1) do
            registry.all do |client_ids|
              expect(client_ids).not_to include('client-1')
              EM.stop
            end
          end
        end
      end
    end

    it 'keeps valid clients in index' do
      em_run do
        registry.create('client-1') do
          registry.cleanup_expired

          EM.add_timer(0.1) do
            registry.all do |client_ids|
              expect(client_ids).to include('client-1')
              EM.stop
            end
          end
        end
      end
    end

    it 'calls callback with number of cleaned clients' do
      em_run do
        registry.create('client-1') do
          registry.create('client-2') do
            registry.create('client-3') do
              # Simulate expiration of 2 clients
              connection.with_redis do |redis|
                redis.del('test:clients:client-1')
                redis.del('test:clients:client-2')
              end

              registry.cleanup_expired do |count|
                expect(count).to eq(2)
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'handles batch cleanup efficiently' do
      em_run do
        # Create multiple clients
        registry.create('client-1') do
          registry.create('client-2') do
            registry.create('client-3') do
              registry.create('client-4') do
                registry.create('client-5') do
                  # Expire 3 clients
                  connection.with_redis do |redis|
                    redis.del('test:clients:client-1')
                    redis.del('test:clients:client-3')
                    redis.del('test:clients:client-5')
                  end

                  registry.cleanup_expired do |count|
                    expect(count).to eq(3)

                    # Verify remaining clients
                    registry.all do |client_ids|
                      expect(client_ids).to contain_exactly('client-2', 'client-4')
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

    it 'handles cleanup with no expired clients' do
      em_run do
        registry.create('client-1') do
          registry.create('client-2') do
            # No clients expired, cleanup should return 0
            registry.cleanup_expired do |count|
              expect(count).to eq(0)
              EM.stop
            end
          end
        end
      end
    end
  end

  describe 'error handling' do
    it 'handles ping errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        expect {
          registry.ping('client-123')
        }.not_to raise_error

        EM.stop
      end
    end

    it 'handles get errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        registry.get('client-123') do |data|
          expect(data).to be_nil
          EM.stop
        end
      end
    end

    it 'handles exists? errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        registry.exists?('client-123') do |exists|
          expect(exists).to be false
          EM.stop
        end
      end
    end

    it 'handles all errors gracefully' do
      em_run do
        # Disconnect to cause error
        connection.disconnect

        registry.all do |client_ids|
          expect(client_ids).to eq([])
          EM.stop
        end
      end
    end

    it 'handles rebuild_clients_index errors gracefully' do
      em_run do
        # Disconnect to cause error during rebuild
        connection.disconnect

        # Should handle error gracefully
        expect {
          registry.send(:rebuild_clients_index)
        }.not_to raise_error

        EM.stop
      end
    end
  end

  describe 'index rebuild (v1.0.9)' do
    it 'rebuilds clients index periodically' do
      em_run do
        # Create some clients
        registry.create('client-1') do
          registry.create('client-2') do
            # Set cleanup counter to 9, next cleanup will trigger rebuild (at 10)
            registry.instance_variable_set(:@cleanup_counter, 9)

            # Trigger cleanup which should increment to 10 and rebuild
            registry.cleanup_expired do
              # After rebuild, cleanup_counter should reset to 0
              expect(registry.instance_variable_get(:@cleanup_counter)).to eq(0)

              # Verify clients are still in index after rebuild
              registry.all do |clients|
                expect(clients).to include('client-1')
                expect(clients).to include('client-2')
                EM.stop
              end
            end
          end
        end
      end
    end

    it 'skips index rebuild when counter below threshold' do
      em_run do
        registry.create('client-1') do
          # Set counter below threshold
          registry.instance_variable_set(:@cleanup_counter, 5)
          initial_counter = 5

          registry.cleanup_expired do
            # Counter should increment, not reset
            expect(registry.instance_variable_get(:@cleanup_counter)).to eq(initial_counter + 1)
            EM.stop
          end
        end
      end
    end

    it 'handles rebuild with no clients' do
      em_run do
        # Trigger rebuild with empty database
        expect {
          registry.send(:rebuild_clients_index)
        }.not_to raise_error

        EM.stop
      end
    end

    it 'handles rebuild with many clients' do
      em_run(2) do
        clients = (1..30).map { |i| "client-#{i}" }
        create_count = 0

        clients.each do |client_id|
          registry.create(client_id) do
            create_count += 1

            if create_count == clients.size
              # Trigger rebuild
              registry.send(:rebuild_clients_index)

              # Verify all clients in index
              registry.all do |all_clients|
                expect(all_clients.size).to eq(clients.size)
                EM.stop
              end
            end
          end
        end
      end
    end
  end
end
