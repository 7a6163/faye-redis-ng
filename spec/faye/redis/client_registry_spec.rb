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
end
