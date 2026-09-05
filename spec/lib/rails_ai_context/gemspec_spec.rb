# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

# A `path:` or vendored Gemfile entry re-evaluates the gemspec in the host
# app, where there is no git checkout, so the file list has to fail quietly.
RSpec.describe "rails-ai-context.gemspec outside a git checkout" do
  let(:repo_root) { File.expand_path("../../..", __dir__) }

  it "writes nothing to stderr" do
    Dir.mktmpdir("gemspec-eval") do |dir|
      FileUtils.cp(File.join(repo_root, "rails-ai-context.gemspec"), dir)
      FileUtils.mkdir_p(File.join(dir, "lib/rails_ai_context"))
      FileUtils.cp(
        File.join(repo_root, "lib/rails_ai_context/version.rb"),
        File.join(dir, "lib/rails_ai_context/version.rb")
      )

      _out, err, status = Open3.capture3(
        { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil },
        RbConfig.ruby, "-e",
        'Gem::Specification.load("rails-ai-context.gemspec")',
        chdir: dir
      )

      expect(status).to be_success
      expect(err).to eq("")
    end
  end
end
