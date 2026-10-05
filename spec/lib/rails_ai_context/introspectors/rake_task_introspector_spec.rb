# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RakeTaskIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns tasks array" do
      expect(result[:tasks]).to be_an(Array)
      expect(result[:tasks]).not_to be_empty
    end

    # From example.rake
    it "discovers namespaced tasks" do
      task_names = result[:tasks].map { |t| t[:name] }
      expect(task_names).to include("example:run", "example:setup")
    end

    it "extracts task descriptions" do
      run_task = result[:tasks].find { |t| t[:name] == "example:run" }
      expect(run_task[:description]).to eq("Run the example task")
    end

    it "extracts file path relative to lib/tasks" do
      run_task = result[:tasks].find { |t| t[:name] == "example:run" }
      expect(run_task[:file]).to eq("example.rake")
    end

    # From complex.rake
    it "discovers deeply nested namespace tasks" do
      task_names = result[:tasks].map { |t| t[:name] }
      expect(task_names).to include("deploy:db:migrate")
    end

    it "extracts descriptions from deeply nested tasks" do
      migrate = result[:tasks].find { |t| t[:name] == "deploy:db:migrate" }
      expect(migrate[:description]).to eq("Migrate staging database")
    end

    it "handles tasks without descriptions" do
      seed = result[:tasks].find { |t| t[:name] == "deploy:db:seed" }
      expect(seed).not_to be_nil
      expect(seed[:description]).to be_nil
    end

    it "discovers top-level tasks (no namespace)" do
      task_names = result[:tasks].map { |t| t[:name] }
      expect(task_names).to include("ping")
    end

    it "assigns correct namespace to all tasks" do
      deploy_staging = result[:tasks].find { |t| t[:name] == "deploy:staging" }
      expect(deploy_staging[:description]).to eq("Deploy to staging")
    end

    context "when lib/tasks does not exist" do
      let(:fake_app) { double(root: Pathname.new("/nonexistent")) }
      let(:introspector) { described_class.new(fake_app) }

      it "returns empty tasks array" do
        expect(result[:tasks]).to eq([])
      end
    end
  end

  # What Rake.application.tasks holds after loading these files.
  context "with brace namespaces, string names, multitask, a Rakefile and rakelib" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:introspector) { described_class.new(double(root: Pathname.new(tmpdir))) }

    before do
      FileUtils.mkdir_p(File.join(tmpdir, "lib", "tasks"))
      FileUtils.mkdir_p(File.join(tmpdir, "rakelib", "nested"))
      File.write(File.join(tmpdir, "lib", "tasks", "leak.rake"), <<~RUBY)
        namespace :alpha do
          namespace(:beta) { task :inside }
          desc "Should be alpha:after"
          task :after
        end

        desc "Old hash-rocket"
        task :legacy_rocket => :environment

        task "string:named" do
        end

        multitask parallel: %w[alpha:after legacy_rocket]
        namespace(:one) { task :a }; task :b
      RUBY
      File.write(File.join(tmpdir, "Rakefile"), "require_relative \"config/application\"\ntask :from_rakefile\n")
      File.write(File.join(tmpdir, "rakelib", "extra.rake"), "task :from_rakelib\n")
      File.write(File.join(tmpdir, "rakelib", "nested", "deep.rake"), "task :not_loaded\n")
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "reads a rake file it cannot parse cleanly without failing the others" do
      File.binwrite(File.join(tmpdir, "lib", "tasks", "broken.rake"), "namespace :x do\n  task \xFF\xFE (\n".b)

      expect(introspector.call[:tasks].map { |t| t[:name] }).to include("legacy_rocket", "from_rakelib")
    end

    it "does not follow a Rakefile, rakelib or lib/tasks symlink out of the app root" do
      outside = Dir.mktmpdir
      File.write(File.join(outside, "outside.rake"), "task :outside_secret_task\n")
      File.symlink(File.join(outside, "outside.rake"), File.join(tmpdir, "rakelib", "linked.rake"))
      File.symlink(File.join(outside, "outside.rake"), File.join(tmpdir, "lib", "tasks", "linked.rake"))
      File.delete(File.join(tmpdir, "Rakefile"))
      File.symlink(File.join(outside, "outside.rake"), File.join(tmpdir, "Rakefile"))

      tasks = introspector.call[:tasks]

      expect(tasks.map { |t| t[:name] }).not_to include("outside_secret_task")
      expect(tasks.map { |t| t[:name] }).to include("from_rakelib", "legacy_rocket")
    ensure
      FileUtils.remove_entry(outside)
    end

    it "parses each rake file from the one read it makes" do
      expect(RailsAiContext::Introspectors::SourceIntrospector).not_to receive(:walk)

      expect(introspector.call[:tasks].map { |t| t[:name] }).to include("from_rakefile", "from_rakelib")
    end

    it "names each task as Rake defines it" do
      tasks = introspector.call[:tasks]

      expect(tasks.map { |t| t[:name] }).to eq(%w[
        from_rakefile alpha:beta:inside alpha:after legacy_rocket string:named parallel one:a b from_rakelib
      ])
      expect(tasks.find { |t| t[:name] == "alpha:after" }[:description]).to eq("Should be alpha:after")
      expect(tasks.find { |t| t[:name] == "parallel" }[:dependencies]).to eq(%w[alpha:after legacy_rocket])
      expect(tasks.map { |t| t[:file] }.uniq).to eq(%w[Rakefile leak.rake rakelib/extra.rake])
    end
  end
end
