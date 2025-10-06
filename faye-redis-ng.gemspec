Gem::Specification.new do |s|
  s.name        = 'faye-redis-ng'
  s.version     = '1.0.0'
  s.summary     = 'Redis backend for Faye'
  s.description = 'A Redis-based backend engine for Faye messaging server, allowing distribution across multiple web servers'
  s.authors     = ['Zac']
  s.email       = 'your.email@example.com'
  s.files       = Dir['lib/**/*.rb'] + ['README.md', 'LICENSE']
  s.homepage    = 'https://github.com/7a6163/faye-redis-ng'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.7.0'

  # Dependencies
  s.add_dependency 'redis', '~> 5.0'
  s.add_dependency 'connection_pool', '~> 2.5'
  s.add_dependency 'eventmachine', '>= 1.0.0'

  # Development dependencies
  s.add_development_dependency 'rspec', '~> 3.12'
  s.add_development_dependency 'rake', '~> 13.0'
end
