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

# The pre-commit hook runs `bundle exec rails-ai-context`, and Bundler
# evaluates a `path:` entry's gemspec there, with the committing
# repository's GIT_DIR and GIT_INDEX_FILE exported by git: absolute in a
# submodule. Read through them, the file list was the app's, with no
# executable in it, and the hook could not start the gem.
RSpec.describe "rails-ai-context.gemspec evaluated inside another repository's git hook" do
  let(:gemspec) { File.expand_path("../../../rails-ai-context.gemspec", __dir__) }

  it "lists its own files, not the committing repository's" do
    Dir.mktmpdir("gemspec-hook") do |app|
      File.write(File.join(app, "only_in_the_app.rb"), "")
      [ %w[init -q], %w[add only_in_the_app.rb] ].each do |args|
        out, status = Open3.capture2e("git", *args, chdir: app)
        raise "git #{args.join(' ')} failed: #{out}" unless status.success?
      end

      hook_env = { "GIT_DIR" => File.join(app, ".git"), "GIT_INDEX_FILE" => File.join(app, ".git", "index"),
                   "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil }
      out, err, status = Open3.capture3(hook_env, RbConfig.ruby, "-e",
                                        "puts Gem::Specification.load(ARGV.first).files", gemspec, chdir: app)

      expect(status).to be_success, err
      expect(out.lines(chomp: true)).to include("exe/rails-ai-context", "lib/rails_ai_context.rb")
      expect(out.lines(chomp: true)).not_to include("only_in_the_app.rb")
    end
  end
end

RSpec.describe "rails-ai-context.gemspec" do
  let(:spec) { Gem::Specification.load(File.expand_path("../../../rails-ai-context.gemspec", __dir__)) }

  it "leaves the README demos and the CI gemfiles out of the packaged gem" do
    expect(spec.files.grep(%r{\A(demo|gemfiles)/})).to be_empty
  end

  # A tool that indexes an app's bundle reads AGENTS.md or CLAUDE.md in a gem's directory as instructions about that app.
  it "packages what a user of the gem runs or reads, and none of the files that serve the repository alone" do
    root = File.expand_path("../../..", __dir__)
    tracked = IO.popen([ "git", "-C", root, "ls-files", "-z" ], &:read).split("\x0")
    code = tracked.grep(%r{\A(lib|exe|app|config)/})
    user_docs = %w[README.md CHANGELOG.md LICENSE SECURITY.md] + tracked.grep(%r{\Adocs/[^/]+\.md\z}) - %w[docs/RELEASING.md]

    expect(spec.files).to include(*code, *user_docs)
    expect(spec.files - code - user_docs).to all(satisfy { |f| links_from_package(root).include?(f) })
    expect(spec.files).not_to include("AGENTS.md", "CLAUDE.md", "CONTEXT.md", "docs/RELEASING.md", "docs/agents/domain.md")
  end

  it "packages every file a packaged Markdown file links to" do
    expect(spec.files).to include(*links_from_package(File.expand_path("../../..", __dir__)))
  end

  # Each relative link of a packaged Markdown file, as a path from the repository root.
  def links_from_package(root)
    spec.files.grep(/\.md\z/).flat_map do |doc|
      File.read(File.join(root, doc)).scan(/\]\(((?!https?:|mailto:|#)[^)#\s]+)/).flatten.map do |link|
        File.expand_path(link, File.join(root, File.dirname(doc))).delete_prefix("#{root}/")
      end
    end.uniq
  end

  # Thor 1.0 and 1.1 raise NameError on require under Ruby 3.1 and later.
  it "requires a thor that loads on every supported Ruby" do
    thor = spec.runtime_dependencies.find { |dep| dep.name == "thor" }
    expect(thor.requirement).not_to be_satisfied_by(Gem::Version.new("1.1.0"))
    expect(thor.requirement).to be_satisfied_by(Gem::Version.new("1.2.0"))
  end
end
