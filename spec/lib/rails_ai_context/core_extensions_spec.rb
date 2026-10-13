# frozen_string_literal: true

require "spec_helper"
require "open3"
require "prism"
require "tmpdir"
require "fileutils"

# With --no-boot an ActiveSupport core extension exists only when the gem's entry file requires
# it. The suite has all of ActiveSupport loaded, so only a clean process can tell.
RSpec.describe "the ActiveSupport core extensions the gem calls" do
  # Method name => where ActiveSupport defines it. Names core Ruby also defines on a common
  # receiver (first, last, at, sum, except) are left out: a call by name cannot tell them apart.
  let(:extensions) do
    {
      to_sentence: "Array", extract_options!: "Array", second: "Array", third: "Array", in_groups_of: "Array",
      squish: "String", truncate: "String", truncate_words: "String", pluralize: "String", singularize: "String",
      underscore: "String", camelize: "String", classify: "String", demodulize: "String", deconstantize: "String",
      constantize: "String", safe_constantize: "String", humanize: "String", titleize: "String",
      parameterize: "String", tableize: "String", foreign_key: "String", dasherize: "String",
      upcase_first: "String", downcase_first: "String", strip_heredoc: "String", starts_with?: "String",
      ends_with?: "String", inquiry: "String", html_safe: "String",
      presence: "Object", blank?: "Object", present?: "Object", deep_dup: "Object", in?: "Object", try: "Object",
      presence_in: "Object", to_query: "Object", to_param: "Object",
      deep_merge: "Hash", deep_merge!: "Hash", deep_symbolize_keys: "Hash", deep_stringify_keys: "Hash",
      deep_transform_keys: "Hash", symbolize_keys: "Hash", stringify_keys: "Hash", reverse_merge: "Hash",
      with_indifferent_access: "Hash", assert_valid_keys: "Hash", extract!: "Hash",
      index_by: "Enumerable", index_with: "Enumerable", exclude?: "Enumerable", compact_blank: "Enumerable",
      excluding: "Enumerable", pluck: "Enumerable", pick: "Enumerable", sole: "Enumerable", many?: "Enumerable",
      to_fs: "Integer", to_formatted_s: "Integer", ago: "Integer", from_now: "Integer", days: "Integer",
      hours: "Integer", minutes: "Integer", seconds: "Integer", weeks: "Integer", months: "Integer",
      years: "Integer", ordinalize: "Integer", kilobytes: "Integer", megabytes: "Integer",
      delegate: "Module", delegate_missing_to: "Module", mattr_accessor: "Module", mattr_reader: "Module",
      cattr_accessor: "Module", class_attribute: "Class", thread_mattr_accessor: "Module"
    }
  end
  # Called without a receiver at class level; every other name counts only on a receiver.
  let(:macros) { %i[delegate delegate_missing_to mattr_accessor mattr_reader cattr_accessor class_attribute thread_mattr_accessor] }

  let(:root) { File.expand_path("../../..", __dir__) }
  let(:lib) { File.join(root, "lib") }
  let(:exe) { File.join(root, "exe/rails-ai-context") }

  def called_extensions
    found = {}
    Dir[File.join(lib, "**/*.rb")].each do |file|
      pending = [ Prism.parse_file(file).value ]
      while (node = pending.pop)
        pending.concat(node.compact_child_nodes)
        next unless node.is_a?(Prism::CallNode) && extensions.key?(node.name)
        next unless node.receiver || macros.include?(node.name)

        found[node.name] ||= "#{file.delete_prefix("#{root}/")}:#{node.location.start_line}"
      end
    end
    found
  end

  it "are all loaded by the entry file, with no Rails in the process" do
    called = called_extensions
    expect(called).to include(:to_sentence, :underscore)

    script = <<~RUBY
      require "rails_ai_context"
      abort("ActiveSupport is fully loaded, so this checks nothing") if defined?(ActiveSupport::Railtie) || defined?(Rails::Application)
      ARGV.each_slice(2) do |name, owner|
        mod = Object.const_get(owner)
        puts name unless mod.method_defined?(name) || mod.private_method_defined?(name)
      end
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script,
                                  *called.keys.flat_map { |name| [ name.to_s, extensions.fetch(name) ] })

    expect(status.exitstatus).to eq(0), out
    missing = out.split.map { |name| "#{extensions.fetch(name.to_sym)}##{name}, called at #{called.fetch(name.to_sym)}" }
    expect(missing).to be_empty, "lib/rails_ai_context.rb does not require:\n#{missing.join("\n")}"
  end

  # A cache database staging and production configure and development does
  # not: the phrase naming the two environments is built with to_sentence.
  describe "through the executable with --no-boot" do
    def cli(dir, *argv)
      Open3.capture2e(RbConfig.ruby, "-I", lib, exe, *argv, "--no-boot", chdir: dir, stdin_data: "")
    end

    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.cp_r(File.join(root, "spec/fixtures/app_databases/two_envs/."), dir)
        @dir = dir
        example.run
      end
    end

    it "context writes its files" do
      out, status = cli(@dir, "context")

      expect(status.exitstatus).to eq(0), out
      expect(File.read(File.join(@dir, "CLAUDE.md"))).to include("cache")
    end

    %w[standard full].each do |detail|
      it "tool onboard answers the walkthrough at #{detail}" do
        out, status = cli(@dir, "tool", "onboard", "--detail", detail)

        expect(status.exitstatus).to eq(0), out
        expect(out).to include("Solid Cache keeps its tables in a database of its own: cache (staging and production).")
        expect(out).not_to match(/error|undefined method/i)
      end
    end

    it "tool schema marks the cache database with the environments that configure it" do
      out, status = cli(@dir, "tool", "schema")

      expect(status.exitstatus).to eq(0), out
      expect(out).to include("- **cache** (staging and production): 1 table")
    end
  end
end
