require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rspec/rails"

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  config.use_transactional_fixtures = true
end
