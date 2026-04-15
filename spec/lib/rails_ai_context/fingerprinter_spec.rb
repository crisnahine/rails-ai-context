# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Fingerprinter do
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

  describe ".reset_gem_lib_fingerprint!" do
    after { described_class.reset_gem_lib_fingerprint! }

    it "clears the memoized ivar so the next compute recomputes it" do
      described_class.compute(Rails.application)
      described_class.reset_gem_lib_fingerprint!
      expect(described_class.instance_variable_get(:@gem_lib_fingerprint)).to be_nil
    end

    it "allows a successful compute after reset" do
      described_class.compute(Rails.application)
      described_class.reset_gem_lib_fingerprint!
      result = described_class.compute(Rails.application)
      expect(result).to match(/\A[a-f0-9]{64}\z/)
    end
  end
end
