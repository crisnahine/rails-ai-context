# frozen_string_literal: true

require_relative "e2e_helper"

# The pre-commit hook the install generator offers, installed by answering
# its question yes and run by real `git commit`s. The harness's own installs
# run outside git and answer no, so nowhere else does the hook run. Git for
# Windows runs a hook under its own sh, so this runs on every OS with git.
#
# One in-Gemfile app, copied into three repositories: at the top of its own,
# in a subfolder of a monorepo, and as a submodule (#425). The generator
# puts the hook where `git rev-parse --git-path hooks` says, and the hook
# checks the staged Ruby, ERB and JavaScript files of each app from inside
# it, through `bundle exec rails-ai-context tool validate`.
RSpec.describe "E2E: the pre-commit hook", type: :e2e do
  before(:all) do
    skip "git is not on PATH: the hook runs only under git" unless E2E::Platform.executable("git")

    source = E2E.shared_app(install_path: :in_gemfile)
    dir = File.join(E2E.root, "pre_commit_hook")

    # The app at the top of its own repository.
    @own = source.copy_to(parent_dir: File.join(dir, "own"), name: "blog")
    commit_everything(@own.app_path)
    @own_install = install_hook(@own)

    # The app in a subfolder of a repository that holds more than the app.
    @monorepo = File.join(dir, "monorepo")
    @mono_app = source.copy_to(parent_dir: File.join(@monorepo, "apps"), name: "blog")
    File.write(File.join(@monorepo, "README.md"), "# monorepo\n")
    commit_everything(@monorepo)
    @mono_install = install_hook(@mono_app)

    # The app as a submodule of a superproject: the app's .git is a file
    # naming its repository under the superproject's .git/modules. `submodule
    # add` of a repository already at the path adds it without cloning.
    @superproject = File.join(dir, "superproject")
    @sub_app = source.copy_to(parent_dir: @superproject, name: "blog")
    commit_everything(@sub_app.app_path)
    File.write(File.join(@superproject, "README.md"), "# superproject\n")
    git!(@superproject, "init", "-q")
    git!(@superproject, "add", "README.md")
    git!(@superproject, "submodule", "add", "./blog", "blog")
    git!(@superproject, "submodule", "absorbgitdirs")
    git!(@superproject, "commit", "-q", "--no-verify", "-m", "the app as a submodule")
    @sub_install = install_hook(@sub_app)
  end

  # git as a person runs it: their name on the command line, which a fresh
  # runner has nowhere else, no signing, and the suite's GIT_CONFIG_* (no
  # background maintenance) inherited. No BUNDLE_GEMFILE: the hook's own cd
  # into the app picks its bundle, as it does in a terminal.
  def git(dir, *args)
    Open3.capture2e(hook_env, "git", "-c", "user.name=E2E", "-c", "user.email=e2e@example.com",
                    "-c", "commit.gpgsign=false", *args, chdir: dir)
  end

  def git!(dir, *args)
    out, status = git(dir, *args)
    raise "git #{args.join(' ')} failed in #{dir}:\n#{out}" unless status.success?

    out
  end

  def hook_env
    E2E.shared_app(install_path: :in_gemfile).env.merge("BUNDLE_GEMFILE" => nil)
  end

  def commit_everything(dir)
    git!(dir, "init", "-q")
    git!(dir, "add", "-A")
    git!(dir, "commit", "-q", "--no-verify", "-m", "before the hook")
  end

  # The generator run again inside the repository, where it asks about the
  # hook: tools and setup as the build answered them, then yes.
  def install_hook(app)
    out, status = Open3.capture2e(app.env, *E2E::TestAppBuilder.script_command(%w[bin/rails generate rails_ai_context:install]),
                                  chdir: app.app_path, stdin_data: "a\n1\ny\n")
    raise "the install generator failed in #{app.app_path}:\n#{out}" unless status.success?

    out
  end

  # Writes and stages `files` (path from the repository's top => content)
  # and commits from the top: the hook's output and status.
  def commit_files(repo, files, message)
    files.each do |relative, content|
      path = File.join(repo, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    git!(repo, "add", "--", *files.keys)
    git(repo, "commit", "-m", message)
  end

  # A refused commit leaves its files staged; nothing after it should see them.
  def discard(repo, *relatives)
    git(repo, "reset", "-q", "--", *relatives)
    relatives.each { |relative| FileUtils.rm_f(File.join(repo, relative)) }
  end

  def head(repo) = git!(repo, "rev-parse", "HEAD").strip
  def head_subject(repo) = git!(repo, "log", "-1", "--format=%s").strip

  def broken_model = "class HookProbe < ApplicationRecord\n  def summary(\nend\n"
  def valid_model = "class HookProbe < ApplicationRecord\n  def summary\n    title\n  end\nend\n"

  # A refused commit leaves HEAD where it was, and the fixed file commits.
  def expect_refused_then_committed(repo, relative)
    before = head(repo)
    out, status = commit_files(repo, { relative => broken_model }, "a model that does not parse")

    expect(status.success?).to be(false), out
    expect(out).to include("rails-ai-context validation found issues.")
    expect(out).to include(File.basename(relative))
    expect(head(repo)).to eq(before)

    out, status = commit_files(repo, { relative => valid_model }, "the model, fixed")
    expect(status.success?).to be(true), out
    expect(head_subject(repo)).to eq("the model, fixed")
  end

  describe "in the app's own repository" do
    it "is installed where git runs it" do
      hook = File.join(@own.app_path, ".git", "hooks", "pre-commit")

      expect(@own_install).to include("Installed pre-commit validation hook")
      expect(File.read(hook)).to include("# rails-ai-context apps: .")
        .and include("bundle exec rails-ai-context tool validate")
      expect(File.executable?(hook)).to be(true) unless Gem.win_platform?
    end

    it "refuses a commit whose staged Ruby file does not parse, and takes it once it does" do
      expect_refused_then_committed(@own.app_path, "app/models/hook_probe.rb")
    end

    # A Stimulus controller is an ES module. Its brace left open fails with
    # node and, without node, the bracket check.
    it "refuses a staged Stimulus controller that does not parse" do
      relative = "app/javascript/controllers/hook_probe_controller.js"
      controller = <<~JS
        import { Controller } from "@hotwired/stimulus"

        export default class extends Controller {
          connect() {
            this.element.textContent = "connected"
          }
      JS
      out, status = commit_files(@own.app_path, { relative => controller }, "a controller that does not parse")

      expect(status.success?).to be(false), out
      expect(out).to include("rails-ai-context validation found issues.").and include("hook_probe_controller.js")
    ensure
      discard(@own.app_path, relative) if relative
    end

    # `<%-` and `-%>` were compiled as a unary minus, so every template
    # written with them failed and the hook blocked the commit.
    it "commits an ERB template written with trim tags" do
      template = <<~ERB
        <%- if @posts.any? -%>
          <ul>
          <%- @posts.each do |post| -%>
            <li><%= post.title %></li>
          <%- end -%>
          </ul>
        <%- end -%>
      ERB
      out, status = commit_files(@own.app_path, { "app/views/posts/_hook_probe.html.erb" => template },
                                 "a partial written with trim tags")

      expect(status.success?).to be(true), out
      expect(head_subject(@own.app_path)).to eq("a partial written with trim tags")
    end

    # The hook validated through the rake task, which has to boot the app and
    # threw stderr away: an app that could not boot blocked every commit, and
    # said nothing about why.
    it "commits a valid file while the app cannot boot, and shows the boot failure" do
      initializer = File.join(@own.app_path, "config", "initializers", "zz_hook_probe_boot.rb")
      File.write(initializer, %(raise "E2E_HOOK_BOOT_FAILURE: REDIS_URL is not set"\n))
      out, status = commit_files(@own.app_path, { "app/models/hook_boot_probe.rb" => "class HookBootProbe < ApplicationRecord\nend\n" },
                                 "a model while the app cannot boot")

      expect(status.success?).to be(true), out
      expect(out).to include("App boot failed").and include("E2E_HOOK_BOOT_FAILURE")
      expect(head_subject(@own.app_path)).to eq("a model while the app cannot boot")
    ensure
      FileUtils.rm_f(initializer) if initializer
    end
  end

  describe "in a subfolder of a repository (#425)" do
    it "is installed once, at the top of the repository, naming the app by its path there" do
      hook = File.join(@monorepo, ".git", "hooks", "pre-commit")

      expect(@mono_install).to include("Installed pre-commit validation hook")
      expect(File.read(hook)).to include("# rails-ai-context apps: apps/blog")
    end

    it "refuses a broken file of the app committed from the top of the repository, and takes it once it parses" do
      expect_refused_then_committed(@monorepo, "apps/blog/app/models/hook_probe.rb")
    end
  end

  describe "as a submodule (#425)" do
    it "is installed in the hooks directory git names for the submodule" do
      hooks = File.expand_path(git!(@sub_app.app_path, "rev-parse", "--git-path", "hooks").strip, @sub_app.app_path)

      expect(File.file?(File.join(@sub_app.app_path, ".git"))).to be(true), "the submodule's .git is no file"
      expect(File.realpath(hooks)).to eq(File.realpath(File.join(@superproject, ".git", "modules", "blog", "hooks")))
      expect(@sub_install).to include("Installed pre-commit validation hook")
      expect(File.read(File.join(hooks, "pre-commit"))).to include("# rails-ai-context apps: .")
    end

    it "refuses a broken file committed inside the submodule, and takes it once it parses" do
      expect_refused_then_committed(@sub_app.app_path, "app/models/hook_probe.rb")
    end
  end
end
