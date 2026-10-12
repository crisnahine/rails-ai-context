# frozen_string_literal: true

require "spec_helper"
require "open3"
require "prism"

# With Rails loaded, and on a Ruby that loads parts of the standard library by itself, a file naming
# a stdlib constant nothing requires passes here and raises NameError elsewhere. Only the source tells.
RSpec.describe "the standard library the shipped code names" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:exe) { "exe/rails-ai-context" }
  let(:entry) { "lib/rails_ai_context.rb" }

  let(:constants) do
    {
      JSON: "json", SecureRandom: "securerandom", Set: "set", Date: "date", DateTime: "date", YAML: "yaml",
      Psych: "psych", FileUtils: "fileutils", Open3: "open3", Digest: "digest", Shellwords: "shellwords",
      Pathname: "pathname", Tempfile: "tempfile", URI: "uri", Net: "net/http", CSV: "csv", StringIO: "stringio",
      Timeout: "timeout", ERB: "erb", OpenSSL: "openssl", Base64: "base64", Benchmark: "benchmark",
      Logger: "logger", DidYouMean: "did_you_mean", Socket: "socket", TCPSocket: "socket", TCPServer: "socket", Etc: "etc",
      Zlib: "zlib", RbConfig: "rbconfig", Ripper: "ripper", Prism: "prism", IRB: "irb", PP: "pp",
      Monitor: "monitor", Singleton: "singleton", Forwardable: "forwardable", StringScanner: "strscan",
      Find: "find", IPAddr: "ipaddr", BigDecimal: "bigdecimal", OpenStruct: "ostruct"
    }
  end
  # Methods a stdlib feature adds to a core class, whatever the receiver.
  let(:methods) do
    {
      to_set: "set", mktmpdir: "tmpdir", to_yaml: "yaml", shelljoin: "shellwords", shellsplit: "shellwords",
      shellescape: "shellwords", iso8601: "time", xmlschema: "time", pretty_inspect: "pp"
    }
  end
  # Called on Time itself these come from "time"; on anything else they are someone else's.
  let(:time_class_methods) { %i[parse strptime rfc2822 httpdate] }
  # A value of one of these exists only once its library is loaded, so a method naming the class
  # was handed one by a file that requires it. Only a reference evaluated at load counts.
  let(:value_types) { %i[Prism] }
  # A feature that loads another as documented behaviour.
  let(:implied) { { "yaml" => %w[psych], "time" => %w[date], "net/http" => %w[uri], "tmpdir" => %w[fileutils] } }

  # { needs: [[feature, name, line]], features: [feature], lazy: [feature a method requires], relatives: [path] }
  def scan(source)
    needs = []
    features = []
    relatives = []
    guarded = []
    lazy = []
    pending = [ [ Prism.parse(source).value, false ] ]
    while ((node, deferred) = pending.pop)
      case node
      when Prism::DefinedNode
        guarded.concat(node.slice.scan(/[A-Z]\w*/).map(&:to_sym))
        next
      when Prism::DefNode
        deferred = true
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        named = constants.key?(node.name) && (node.is_a?(Prism::ConstantReadNode) || node.parent.nil?)
        needs << [ constants[node.name], node.name, node.location.start_line ] if named && !(deferred && value_types.include?(node.name))
      when Prism::CallNode
        first, second = node.arguments&.arguments.to_a
        if node.receiver.nil? && node.name == :require && first.is_a?(Prism::StringNode)
          features << first.unescaped
          lazy << first.unescaped if deferred
        elsif node.receiver.nil? && node.name == :require_relative && first.is_a?(Prism::StringNode)
          relatives << first.unescaped
        elsif node.name == :autoload && second.is_a?(Prism::StringNode)
          features << second.unescaped
        elsif methods.key?(node.name) && node.receiver
          needs << [ methods[node.name], node.name, node.location.start_line ]
        elsif time_class_methods.include?(node.name) && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Time
          needs << [ "time", :"Time.#{node.name}", node.location.start_line ]
        end
      end
      pending.concat(node.compact_child_nodes.map { |child| [ child, deferred ] })
    end
    { needs: needs.reject { |_, name, _| guarded.include?(name) }, features: features, lazy: lazy, relatives: relatives }
  end

  def provided?(feature, features)
    features.any? { |have| have == feature || have.start_with?("#{feature}/") || implied.fetch(have, []).include?(feature) }
  end

  # What the source names and nothing in `loaded` or the source itself requires.
  def misses(source, loaded = [])
    found = scan(source)
    found[:needs].reject { |feature, _, _| provided?(feature, found[:features] + loaded) }
                 .map { |feature, name, line| [ name, feature, line ] }
  end

  def read(path)
    File.read(File.join(root, path))
  end

  def report(path, source, loaded)
    misses(source, loaded).uniq { |name, _, _| name }
                          .map { |name, feature, line| "#{path}:#{line} names #{name}, needs require \"#{feature}\"" }
  end

  # The files require_install_files! loads and the files those require, each
  # after the ones it requires: the order they finish loading in.
  def install_path
    list = read(exe).slice(/def require_install_files!\s*\n\s*%w\[(.*?)\]/m, 1).split
    seen = []
    order = []
    visit = lambda do |path|
      next if seen.include?(path) || !File.file?(File.join(root, path))

      seen << path
      scan(read(path))[:relatives].each do |relative|
        visit.call(File.expand_path("#{relative.delete_suffix('.rb')}.rb", "/#{File.dirname(path)}").delete_prefix("/"))
      end
      order << path
    end
    list.each { |name| visit.call("lib/rails_ai_context/#{name}.rb") }
    order
  end

  describe "the scan" do
    it "finds a constant the file never requires" do
      expect(misses("module Demo\n  def self.call = JSON.parse(\"{}\")\nend\n")).to eq([ [ :JSON, "json", 2 ] ])
    end

    it "finds a method only a stdlib feature defines" do
      expect(misses("x = [1].to_set\nTime.parse(y)\nDir.mktmpdir\n"))
        .to eq([ [ :mktmpdir, "tmpdir", 3 ], [ :"Time.parse", "time", 2 ], [ :to_set, "set", 1 ] ])
    end

    it "takes a require, an autoload, a nested feature and an implied one" do
      source = <<~RUBY
        require "json"
        require "digest/sha2"
        require "yaml"
        autoload :SecureRandom, "securerandom"
        def call = [ JSON, ::Digest::SHA256, Psych, SecureRandom.hex ]
      RUBY

      expect(misses(source)).to be_empty
    end

    it "counts a parser node class only where the file names it while loading" do
      source = "class Demo < Prism::Visitor\n  KINDS = [ Prism::CallNode ].freeze\n  def call(node) = node.is_a?(Prism::DefNode)\n  def parse(text) = JSON.parse(text)\nend\n"

      expect(misses(source).sort_by(&:last)).to eq([ [ :Prism, "prism", 1 ], [ :Prism, "prism", 2 ], [ :JSON, "json", 4 ] ])
    end

    it "takes a feature a file loaded earlier requires" do
      expect(misses("Set.new", %w[set])).to be_empty
    end

    it "passes over a name in a comment, a string, a namespace or a defined? check" do
      source = <<~RUBY
        # CSV rows
        text = "SecureRandom.hex(4)"
        Demo::JSON.parse(text)
        ::DidYouMean::SpellChecker.new(dictionary: []) if defined?(::DidYouMean::SpellChecker)
      RUBY

      expect(misses(source)).to be_empty
    end
  end

  it "is required by the file that names it or by the entry file" do
    loaded = scan(read(entry))[:features]
    strict = install_path + [ exe ]
    files = Dir[File.join(root, "lib/**/*.{rb,rake}")].map { |file| file.delete_prefix("#{root}/") }.sort - strict

    expect(files.size).to be > 100
    offenders = files.flat_map { |path| report(path, read(path), loaded) }
    expect(offenders).to be_empty, offenders.join("\n")
  end

  # A spec file runs after spec_helper, the support files and the entry file. What Rails happens
  # to load besides differs by version, so it does not count.
  it "is required by the spec file that names it, by spec_helper or by the entry file" do
    helpers = [ "spec/spec_helper.rb" ] + Dir[File.join(root, "spec/support/**/*.rb")].map { |file| file.delete_prefix("#{root}/") }
    loaded = scan(read(entry))[:features] + helpers.flat_map { |path| scan(read(path))[:features] }
    files = Dir[File.join(root, "spec/**/*.rb")].map { |file| file.delete_prefix("#{root}/") }.sort
    files.reject! { |path| path.start_with?("spec/internal/", "spec/fixtures/") }

    expect(files.size).to be > 100
    offenders = files.flat_map { |path| report(path, read(path), loaded) }
    expect(offenders).to be_empty, offenders.join("\n")
  end

  # The install path loads before the entry file, so the entry's requires do
  # not count there, and nothing but the exe's own requires counts in the exe.
  it "is required on the install path by the file itself or one loaded before it" do
    order = install_path
    expect(order).to include("lib/rails_ai_context/install/uninstall.rb", "lib/rails_ai_context/install_mode.rb")

    loaded = []
    offenders = order.flat_map do |path|
      source = read(path)
      loaded.concat(scan(source)[:features])
      report(path, source, loaded)
    end
    offenders.concat(report(exe, read(exe), []))

    expect(offenders).to be_empty, offenders.join("\n")
  end

  it "defines every constant the install path names, in a process that loaded nothing else" do
    order = install_path
    scans = order.map { |path| scan(read(path)) }
    # A library a method requires for itself is not loaded until that method runs.
    eager = scans.flat_map { |found| found[:features] - found[:lazy] }
    named = scans.flat_map { |found| found[:needs].map { |_, name, _| name } }.uniq
                 .select { |name| constants.key?(name) && provided?(constants[name], eager) }
    expect(named).to include(:FileUtils)

    script = <<~RUBY
      #{order.map { |path| "require #{File.join(root, path).inspect}" }.join("\n")}
      abort("the entry file is loaded, so this checks nothing") if defined?(Zeitwerk) || defined?(ActiveSupport)
      puts ARGV.reject { |name| Object.const_defined?(name) }
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-e", script, *named.map(&:to_s))

    expect(status.exitstatus).to eq(0), out
    expect(out.split).to be_empty
  end

  it "maps each constant in use to the feature that defines it" do
    files = Dir[File.join(root, "lib/**/*.{rb,rake}")] + [ File.join(root, exe) ]
    named = files.flat_map { |file| scan(File.read(file))[:needs].map { |_, name, _| name } }.uniq.select { |name| constants.key?(name) }

    script = <<~RUBY
      ARGV.each_slice(2) do |name, feature|
        require feature
        puts name unless Object.const_defined?(name)
      end
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-e", script, *named.flat_map { |name| [ name.to_s, constants.fetch(name) ] })

    expect(status.exitstatus).to eq(0), out
    expect(out.split).to be_empty
  end
end
