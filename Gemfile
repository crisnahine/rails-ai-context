# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Default tracks the minimum supported Rails version so local bundle
# resolution exercises the support floor unless CI overrides it.
rails_version = ENV.fetch("RAILS_VERSION", "7.0")

group :development, :test do
  gem "pry", "~> 0.14"
  gem "railties", "~> #{rails_version}.0"
  gem "activerecord", "~> #{rails_version}.0"
  # Rails 7.0–7.2 requires sqlite3 ~> 1.4; Rails 8+ supports both 1.x and 2.x.
  gem "sqlite3", "~> 1.4"
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails", require: false
end
