# frozen_string_literal: true

source "https://rubygems.org"

gemspec

eval_gemfile "gemfiles/rails.gemfile"

group :development, :test do
  gem "pry", "~> 0.14"

  gem "rubocop-rails-omakase", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails", require: false
end
