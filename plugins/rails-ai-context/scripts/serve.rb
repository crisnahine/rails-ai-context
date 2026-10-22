#!/usr/bin/env ruby
# frozen_string_literal: true

# Starts the installed gem's own binary through `ruby`, which every platform
# can start without a shell; the gem's binstub is a batch file on Windows.
abort "rails-ai-context needs Ruby 3.1 or later; #{Gem.ruby} is #{RUBY_VERSION}." if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1")

# As the RubyGems binstub does, for RUBYGEMS_GEMDEPS.
Gem.use_gemdeps
begin
  bin = Gem.activate_bin_path("rails-ai-context", "rails-ai-context", ">= 0.a")
rescue Gem::LoadError, Gem::GemNotFoundException => e
  abort "rails-ai-context cannot start under #{Gem.ruby}: #{e.message}" if Gem::Specification.any? { |spec| spec.name == "rails-ai-context" }

  abort "rails-ai-context is not installed for #{Gem.ruby}. Run `gem install rails-ai-context` " \
        "with that Ruby; an app that also has it in its Gemfile gets its bundled copy."
end

# The binary's own advice where it finds no single app is --app-path, which this entry cannot pass.
begin
  require "rails_ai_context/cli/app_root"
  found = RailsAiContext::CLI::AppRoot.resolve(cwd: Dir.pwd)
  if found.root.nil? && found.below.size > 1
    abort "#{Dir.pwd} holds #{found.below.size} Rails apps (#{found.below.map { |path| File.basename(path) }.sort.join(", ")}), " \
          "and the plugin serves one: start Claude Code in that app's folder. For one session over all of them, " \
          "use the workspace setup `rails-ai-context init` writes, without the plugin."
  end
  abort "#{Dir.pwd} holds no Rails app: start Claude Code in a Rails app's folder." if found.root.nil?
rescue LoadError
  nil
end

ARGV.replace([ "serve" ])
load bin
