# frozen_string_literal: true
$VERBOSE = nil

require 'simplecov'
SimpleCov.start

ENV['RACK_ENV'] = 'test'
ENV['QUIET'] = 'true'

module AutoscanDisabler
  def start; end
  def start_wal_checkpoint_thread; end
end

require_relative '../background_tile_loader'
BackgroundTileLoader.prepend(AutoscanDisabler)

require 'rspec-benchmark'
require 'rack/test'
require 'async/rspec'
require 'rack/builder'

$app = Rack::Builder.parse_file(File.expand_path 'config.ru')

module Rack::Test::JHelpers
  def app = $app
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.include Rack::Test::JHelpers
  config.include RSpec::Benchmark::Matchers
  config.include_context Async::RSpec::Reactor

  config.before(:each) do
    header 'Host', 'localhost'
  end

  config.after(:each) do
    ROUTES.each { |_, route| route[:client]&.close } if defined?(ROUTES)
  end
end
