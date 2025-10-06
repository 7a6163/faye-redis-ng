require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc 'Run all tests'
task :test => :spec

desc 'Run tests with coverage'
task :coverage do
  ENV['COVERAGE'] = 'true'
  Rake::Task[:spec].invoke
end

desc 'Check if Redis is running'
task :check_redis do
  require 'redis'
  begin
    redis = Redis.new
    redis.ping
    puts '✅ Redis is running'
    redis.quit
  rescue => e
    puts '❌ Redis is not running'
    puts "   Error: #{e.message}"
    puts '   Please start Redis: redis-server'
    exit 1
  end
end

desc 'Setup test database'
task :setup_test_db => :check_redis do
  require 'redis'
  redis = Redis.new(db: 15)
  redis.flushdb
  puts '✅ Test database cleaned'
  redis.quit
end

desc 'Run linter'
task :lint do
  puts 'Running Ruby linter...'
  system('ruby -c lib/faye-redis-ng.rb')
  Dir['lib/**/*.rb'].each do |file|
    system("ruby -c #{file}")
  end
end
