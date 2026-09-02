# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Fingerprinter do
  # A throwaway copy of the fixture app: these examples push mtimes into the
  # future, which must not follow the suite back into spec/internal.
  let(:app) do
    @tmp_app_root = Dir.mktmpdir
    FileUtils.cp_r(File.join(Rails.root.to_s, "."), @tmp_app_root)
    FileUtils.touch(File.join(@tmp_app_root, "Gemfile.lock"))
    RailsAiContext::StaticApp.new(@tmp_app_root)
  end

  after { FileUtils.remove_entry(@tmp_app_root) if @tmp_app_root && Dir.exist?(@tmp_app_root) }

  describe ".compute" do
    it "returns a hex digest string" do
      result = described_class.compute(Rails.application)
      expect(result).to match(/\A[a-f0-9]{64}\z/)
    end

    it "returns the same value on repeated calls with no changes" do
      a = described_class.compute(Rails.application)
      b = described_class.compute(Rails.application)
      expect(a).to eq(b)
    end

    it "detects changes to .rake files" do
      before = described_class.compute(Rails.application)
      rake_file = File.join(Rails.root, "lib/tasks/example.rake")
      original_mtime = File.mtime(rake_file)

      # Touch the file to change mtime
      FileUtils.touch(rake_file)
      after = described_class.compute(Rails.application)

      # Restore original mtime
      File.utime(original_mtime, original_mtime, rake_file)

      expect(before).not_to eq(after)
    end

    it "detects changes to .erb view files" do
      before = described_class.compute(Rails.application)
      erb_file = File.join(Rails.root, "app/views/posts/index.html.erb")
      original_mtime = File.mtime(erb_file)

      FileUtils.touch(erb_file)
      after = described_class.compute(Rails.application)

      File.utime(original_mtime, original_mtime, erb_file)

      expect(before).not_to eq(after)
    end

    it "detects changes to .js stimulus controllers" do
      # Use permanent hello_controller.js fixture
      js_file = File.join(Rails.root, "app/javascript/controllers/hello_controller.js")
      original_mtime = File.mtime(js_file)

      before = described_class.compute(Rails.application)
      FileUtils.touch(js_file)
      after = described_class.compute(Rails.application)

      File.utime(original_mtime, original_mtime, js_file)

      expect(before).not_to eq(after)
    end

    it "includes app/components in WATCHED_DIRS" do
      expect(described_class::WATCHED_DIRS).to include("app/components")
    end

    it "includes package.json in WATCHED_FILES" do
      expect(described_class::WATCHED_FILES).to include("package.json")
    end

    it "includes tsconfig.json in WATCHED_FILES" do
      expect(described_class::WATCHED_FILES).to include("tsconfig.json")
    end

    it "includes the Gemfile in WATCHED_FILES" do
      expect(described_class::WATCHED_FILES).to include("Gemfile")
    end

    it "watches a packwerk pack's models, so a pack edit invalidates the cache" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "packs", "billing", "app", "models"))
        dirs = described_class.send(:watched_dirs, root)
        expect(dirs).to include(File.join(root, "packs", "billing", "app", "models"))
      end
    end

    it "watches every concern home the resolver names" do
      require "tmpdir"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "serializers", "concerns"))
        dirs = described_class.send(:watched_dirs, root)
        expect(dirs).to include(File.join(root, "app", "serializers", "concerns"))
      end
    end

    it "detects changes to package.json" do
      package_json = File.join(Rails.root, "package.json")
      next unless File.exist?(package_json)

      before = described_class.compute(Rails.application)
      original_mtime = File.mtime(package_json)

      FileUtils.touch(package_json)
      after = described_class.compute(Rails.application)

      File.utime(original_mtime, original_mtime, package_json)

      expect(before).not_to eq(after)
    end
  end

  describe ".changed?" do
    it "returns false when fingerprint matches" do
      current = described_class.compute(Rails.application)
      expect(described_class.changed?(Rails.application, current)).to be false
    end

    it "returns true when fingerprint differs" do
      expect(described_class.changed?(Rails.application, "stale")).to be true
    end
  end

  describe ".mark and .stale?" do
    it "is not stale until a watched file changes" do
      mark = described_class.mark(app)
      expect(described_class.stale?(app, mark)).to be false

      path = File.join(app.root, "app/models/post.rb")
      File.utime(Time.now + 5, Time.now + 5, path)
      expect(described_class.stale?(app, mark)).to be true
    end

    # config/routes.rb is covered by the config directory, not by a file entry.
    it "goes stale when config/routes.rb changes" do
      mark = described_class.mark(app)
      path = File.join(app.root, "config/routes.rb")
      File.utime(Time.now + 5, Time.now + 5, path)

      expect(described_class.stale?(app, mark)).to be true
    end
  end

  describe ".changed_since" do
    it "names the directories with a file newer than the time, root-relative" do
      path = File.join(app.root, "app/models/post.rb")
      File.utime(Time.now + 5, Time.now + 5, path)
      expect(described_class.changed_since(app.root, Time.now)).to include("app/models")
      expect(described_class.changed_since(app.root, Time.now + 10)).to eq([])
    end
  end

  describe ".watched_files" do
    it "lists the root manifests that exist" do
      expect(described_class.watched_files(app.root)).to include(File.join(app.root, "Gemfile.lock"))
    end
  end
end
