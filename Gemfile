# frozen_string_literal: true

source "https://rubygems.org"

gemspec

rails_version = ENV.fetch("RAILS_VERSION", "8.0")

group :development, :test do
  gem "pry", "~> 0.14"
  gem "railties", "~> #{rails_version}.0"
  gem "activerecord", "~> #{rails_version}.0"

  # Rails 7.0's sqlite3 adapter caps at sqlite3 ~> 1.4; the 2.x line is only
  # supported from Rails 7.1 on. Newer Rails resolves sqlite3 2.x unpinned.
  if rails_version == "7.0"
    gem "sqlite3", "~> 1.4"
  else
    gem "sqlite3"
  end

  # concurrent-ruby 1.3.5 dropped its implicit `require "logger"`. Rails < 7.1
  # relies on Logger being loaded at boot, so pull it in explicitly; harmless
  # on 7.1+, which requires logger itself.
  gem "logger"

  gem "rubocop-rails-omakase", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails", require: false
end
