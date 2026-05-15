# frozen_string_literal: true

source "https://rubygems.org"

gemspec

rails_version = ENV.fetch("RAILS_VERSION", "7.0")

group :development, :test do
  gem "pry", "~> 0.14"
  gem "railties", "~> #{rails_version}.0"
  gem "activerecord", "~> #{rails_version}.0"
  gem "sqlite3"
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails", require: false
end
