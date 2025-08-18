# frozen_string_literal: true
$VERBOSE = nil

require 'rspec-benchmark'
require 'rack/test'
require 'async/rspec'
require 'rack/builder'

require 'simplecov'
SimpleCov.start

ENV['DB_URL'] = 'sqlite::memory:'
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
    ROUTES.each do |_, route|
      route[:client].close if route[:client]
    end
  end
end