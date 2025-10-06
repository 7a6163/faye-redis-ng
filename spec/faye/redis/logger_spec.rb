require 'spec_helper'

RSpec.describe Faye::Redis::Logger do
  let(:component) { 'TestComponent' }
  let(:options) { { log_level: :info } }
  let(:logger) { described_class.new(component, options) }

  describe '#initialize' do
    it 'sets the component name' do
      expect(logger.component).to eq(component)
    end

    it 'sets default log level to info' do
      logger = described_class.new(component, {})
      expect(logger.level).to eq(2) # info level
    end

    it 'accepts custom log level' do
      logger = described_class.new(component, log_level: :debug)
      expect(logger.level).to eq(3) # debug level
    end

    it 'handles silent log level' do
      logger = described_class.new(component, log_level: :silent)
      expect(logger.level).to eq(0) # silent level
    end
  end

  describe '#error' do
    it 'logs error messages when level is error or higher' do
      logger = described_class.new(component, log_level: :error)
      expect { logger.error('test error') }.to output(/ERROR: test error/).to_stdout
    end

    it 'includes component name in output' do
      expect { logger.error('test error') }.to output(/\[TestComponent\]/).to_stdout
    end

    it 'includes timestamp in output' do
      expect { logger.error('test error') }.to output(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/).to_stdout
    end

    it 'does not log when level is silent' do
      logger = described_class.new(component, log_level: :silent)
      expect { logger.error('test error') }.not_to output.to_stdout
    end
  end

  describe '#info' do
    it 'logs info messages when level is info or higher' do
      expect { logger.info('test info') }.to output(/INFO: test info/).to_stdout
    end

    it 'does not log when level is error' do
      logger = described_class.new(component, log_level: :error)
      expect { logger.info('test info') }.not_to output.to_stdout
    end

    it 'does not log when level is silent' do
      logger = described_class.new(component, log_level: :silent)
      expect { logger.info('test info') }.not_to output.to_stdout
    end
  end

  describe '#debug' do
    it 'logs debug messages when level is debug' do
      logger = described_class.new(component, log_level: :debug)
      expect { logger.debug('test debug') }.to output(/DEBUG: test debug/).to_stdout
    end

    it 'does not log when level is info' do
      expect { logger.debug('test debug') }.not_to output.to_stdout
    end

    it 'does not log when level is error' do
      logger = described_class.new(component, log_level: :error)
      expect { logger.debug('test debug') }.not_to output.to_stdout
    end

    it 'does not log when level is silent' do
      logger = described_class.new(component, log_level: :silent)
      expect { logger.debug('test debug') }.not_to output.to_stdout
    end
  end

  describe 'log level hierarchy' do
    it 'silent logs nothing' do
      logger = described_class.new(component, log_level: :silent)
      expect {
        logger.error('error')
        logger.info('info')
        logger.debug('debug')
      }.not_to output.to_stdout
    end

    it 'error logs only errors' do
      logger = described_class.new(component, log_level: :error)
      expect { logger.error('error') }.to output.to_stdout
      expect { logger.info('info') }.not_to output.to_stdout
      expect { logger.debug('debug') }.not_to output.to_stdout
    end

    it 'info logs errors and info' do
      logger = described_class.new(component, log_level: :info)
      expect { logger.error('error') }.to output.to_stdout
      expect { logger.info('info') }.to output.to_stdout
      expect { logger.debug('debug') }.not_to output.to_stdout
    end

    it 'debug logs everything' do
      logger = described_class.new(component, log_level: :debug)
      expect { logger.error('error') }.to output.to_stdout
      expect { logger.info('info') }.to output.to_stdout
      expect { logger.debug('debug') }.to output.to_stdout
    end
  end
end
