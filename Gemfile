# frozen_string_literal: true

source "https://rubygems.org"

gemspec

eval_gemfile "gemfiles/rails.gemfile"

group :development, :test do
  gem "pry", "~> 0.14"
end

# The website build (scripts/site.rb) renders docs/ with the engine GitHub Pages' Jekyll used.
group :site do
  gem "kramdown", "~> 2.4"
  gem "kramdown-parser-gfm", "~> 1.1"
  gem "rouge", ">= 4.0", "< 6"
end
