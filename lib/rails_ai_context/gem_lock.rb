# frozen_string_literal: true

require_relative "safe_file"

module RailsAiContext
  # Which gems an app resolved, read once per lockfile, and the one answer
  # every caller gets: a gem is present by exact name, so `bugsnag` is not
  # `bugsnag-capistrano`, and a git or path gem counts like any other.
  # Bundler's own parser needs a Gemfile it can locate and raises without one,
  # which the standalone binary never has, so the spec-line grammar is read
  # here: a section header, a specs: line, then one four-space line per gem
  # with its version in parentheses.
  module GemLock
    MAX_SIZE = 5 * 1024 * 1024
    SPEC_LINE = /\A {4}(\S+) \(([^)]+)\)\s*\z/
    RUBY_LINE = /\A {3}ruby (\S+)/

    class Spec
      attr_reader :ruby_version

      def initialize(versions, ruby_version: nil, missing: false)
        @versions = versions
        @ruby_version = ruby_version
        @missing = missing
      end

      def missing?
        @missing
      end

      def present?(name)
        @versions.key?(name.to_s)
      end

      def version(name)
        @versions[name.to_s]
      end

      def any?(*names)
        names.flatten.any? { |name| present?(name) }
      end

      def names
        @versions.keys.sort
      end
    end

    MUTEX = Mutex.new
    CACHE = {}
    private_constant :MUTEX, :CACHE

    module_function

    def for(root)
      path = File.join(root.to_s, "Gemfile.lock")
      stamp = begin
        File.mtime(path)
      rescue SystemCallError
        nil
      end

      MUTEX.synchronize do
        cached = CACHE[path]
        return cached[:spec] if cached && cached[:stamp] == stamp

        spec = stamp ? parse(path) : Spec.new({}, missing: true)
        CACHE[path] = { stamp: stamp, spec: spec }
        spec
      end
    end

    def parse(path)
      content = SafeFile.read(path, max_size: MAX_SIZE)
      return Spec.new({}, missing: true) unless content

      versions = {}
      ruby_version = nil
      in_specs = false
      content.each_line do |line|
        if line.match?(/\A\S/)
          in_specs = false
        elsif line.strip == "specs:"
          in_specs = true
        elsif in_specs && (match = line.match(SPEC_LINE))
          # A platform-specific gem is "name (1.2.3-x86_64-linux)", one line
          # per platform. The text before the first hyphen is the version; a
          # prerelease tag ("1.70.0-beta1") is dropped along with the platform.
          versions[match[1]] ||= match[2].split("-", 2).first
        elsif (match = line.match(RUBY_LINE))
          ruby_version = match[1]
        end
      end
      Spec.new(versions, ruby_version: ruby_version, missing: false)
    end
    private_class_method :parse
  end
end
