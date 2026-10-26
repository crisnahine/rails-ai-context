#!/usr/bin/env ruby
# frozen_string_literal: true

# Starts the installed gem's own binary through `ruby`, which every platform
# can start without a shell; the gem's binstub is a batch file on Windows.
# Ruby parses this whole file before the version check runs, so it keeps to syntax Ruby 2.3 reads.

# Where the gem cannot serve, a server that answers the handshake with no tools and the reason:
# Claude Code skips a plugin server that failed to start, in every folder, for some minutes after.
def refuse(reason)
  # A C locale tags the folder's name and each line binary or US-ASCII, which json refuses to write or parse.
  utf8 = lambda { |text| text.dup.force_encoding(Encoding::UTF_8).scrub }
  reason = utf8.call(reason)
  $stderr.puts reason
  # RubyGems would activate the newest json installed, which a Ruby too old for the gem may not parse.
  begin
    json = Gem::Specification.find_all_by_name("json").find(&:default_gem?)
    gem "json", json.version.to_s if json
  rescue StandardError, Gem::LoadError
    nil
  end
  require "json"
  $stdout.sync = true
  $stdin.each_line do |line|
    request = begin
      JSON.parse(utf8.call(line))
    rescue JSON::ParserError
      nil
    end
    next unless request.is_a?(Hash) && request.key?("id")

    params = request["params"].is_a?(Hash) ? request["params"] : {}
    answer = case request["method"]
    when "initialize"
      { "result" => { "protocolVersion" => params["protocolVersion"] || "2024-11-05", "capabilities" => { "tools" => {} },
                      "serverInfo" => { "name" => "rails-ai-context", "version" => "0" }, "instructions" => reason } }
    when "tools/list" then { "result" => { "tools" => [] } }
    when "ping" then { "result" => {} }
    else { "error" => { "code" => -32_601, "message" => reason } }
    end
    $stdout.puts JSON.generate({ "jsonrpc" => "2.0", "id" => request["id"] }.merge(answer))
  end
  exit
end

def refuse_bundle(ruby, reason, requirement)
  gemfile = begin
    ::Bundler.default_gemfile
  rescue StandardError
    ENV["BUNDLE_GEMFILE"]
  end
  refuse "rails-ai-context cannot start under #{ruby}: #{reason} The bundle of #{gemfile} came with the environment " \
         "Claude Code started in. Start Claude Code outside `bundle exec`, without the RUBYOPT or BUNDLER_SETUP it sets, " \
         "or have that bundle carry rails-ai-context #{requirement}."
end

def refuse_old(version, ruby, requirement)
  refuse "rails-ai-context #{version} is installed for #{ruby}, and the plugin needs #{requirement}. " \
         "Run `gem update rails-ai-context` with that Ruby."
end

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.1")
  refuse "rails-ai-context needs Ruby 3.1 or later; #{Gem.ruby} is #{RUBY_VERSION}, the `ruby` on Claude Code's PATH, run in " \
         "#{Dir.pwd}. Start Claude Code where Ruby 3.1 or later is active."
end
require_relative "gem_requirement"

requirement = Gem::Requirement.new(RailsAiContextPlugin::GEM_REQUIREMENT)
ruby = "#{Gem.ruby} (Ruby #{RUBY_VERSION}, the `ruby` on Claude Code's PATH, run in #{Dir.pwd})"

# No Gem.use_gemdeps, unlike the binstub: the binary hands an app to its own
# bundle, and an inherited RUBYGEMS_GEMDEPS would only refuse the gem.
begin
  bin = Gem.activate_bin_path("rails-ai-context", "rails-ai-context", requirement.to_s)
rescue StandardError, Gem::LoadError => e
  # One line: Ruby 3.1 adds error_highlight's snippet to a NameError's message itself, and its
  # original_message on a RubyGems error is the class name alone.
  text = e.is_a?(NameError) && e.respond_to?(:original_message) ? e.original_message : e.message
  reason = text.split("\n").map(&:strip).reject(&:empty?).join(" ")
  # bundler/setup leaves only the bundle's gems in reach, whatever else is installed.
  refuse_bundle(ruby, reason, requirement) if defined?(::Bundler)

  newest = begin
    Gem::Specification.find_all_by_name("rails-ai-context").map(&:version).max
  rescue StandardError
    refuse "rails-ai-context cannot start under #{ruby}: #{reason}"
  end
  refuse_old(newest, ruby, requirement) if newest && !requirement.satisfied_by?(newest)
  refuse "rails-ai-context cannot start under #{ruby}: #{reason}" if newest

  refuse "rails-ai-context is not installed for #{ruby}. Run `gem install rails-ai-context` with that Ruby; " \
         "a bundle installed into vendor/bundle is not where it looks."
end

# Bundler's activate_bin_path drops the requirement, so an inherited bundle may lock an older copy.
spec = Gem.loaded_specs["rails-ai-context"]
if spec && !requirement.satisfied_by?(spec.version)
  refuse_bundle(ruby, "That bundle locks rails-ai-context #{spec.version}.", requirement) if defined?(::Bundler)
  refuse_old(spec.version, ruby, requirement)
end

# A gem with the refusal answers by handshake whatever stops its serve, and serves a folder of apps itself.
if RailsAiContextPlugin.routes?
  ENV["RAILS_AI_CONTEXT_PLUGIN"] = "1"
  ARGV.replace([ "serve" ])
  begin
    load bin
  rescue SystemExit => e
    raise if e.success?

    refuse "rails-ai-context serve stopped under #{ruby} (exit #{e.status}); the lines before this one say why."
  rescue ScriptError, StandardError => e
    refuse "rails-ai-context cannot start under #{ruby}: #{e.message.split("\n").map(&:strip).reject(&:empty?).join(" ")}"
  end
  exit
end

# The binary's own advice where it finds no single app is --app-path, which this entry cannot pass.
require "rails_ai_context/cli/app_root"
found = RailsAiContext::CLI::AppRoot.resolve(cwd: Dir.pwd)
if found.root.nil? && found.below.size > 1
  apps = found.below.map { |path| RailsAiContext::CLI::AppRoot.display(path, Dir.pwd) }
  # Project scope is read from the folder a session starts in alone, so the apps keep the plugin.
  refuse "#{Dir.pwd} holds #{found.below.size} Rails apps (#{apps.join(", ")}), and the plugin serves one: " \
         "start Claude Code in one of them. Until then, each app's tools run as " \
         "`rails-ai-context --app-path <app> tool <name>`, with <app> one of: #{apps.join(", ")}. For one session over all of them, use the workspace setup " \
         "`rails-ai-context init` writes, and turn the plugin off for this folder alone with " \
         "`claude plugin disable rails-ai-context@rails-ai-context --scope project` run here, or with `--scope local` where " \
         "a --scope local install turns it on. On macOS and Linux, a local setting at the root of a git repository " \
         "the apps share reaches them too."
end
refuse "#{Dir.pwd} holds no Rails app: start Claude Code in a Rails app's folder." if found.root.nil?

ARGV.replace([ "serve" ])
load bin
