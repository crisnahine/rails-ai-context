# frozen_string_literal: true

require "spec_helper"

# Both walks glob a directory and then read what they found. `spec/` is a live
# directory - an example writes a model into the dummy app and removes it again
# - so a second suite running beside this one can delete a path between the
# glob and the read, and a file that is gone is not a file that breaks the
# rule. `lib/` is not live, so a file that cannot be read there is a fault this
# walk must not swallow: its whole job is to be loud.
module DisciplineWalk
  module_function

  def ruby_files(root)
    Dir.glob(File.join(root, "**", "*.rb"))
  end

  def uncommented_lines(file)
    File.readlines(file).reject { |l| l.strip.start_with?("#") }
  end

  def uncommented_lines_if_present(file)
    uncommented_lines(file)
  rescue Errno::ENOENT
    []
  end
end

RSpec.describe DisciplineWalk do
  let(:missing) { File.join(Dir.tmpdir, "discipline-walk-#{Process.pid}-gone.rb") }

  it "reads no lines from a file that is gone by the time it is opened" do
    expect { described_class.uncommented_lines_if_present(missing) }.not_to raise_error
    expect(described_class.uncommented_lines_if_present(missing)).to eq([])
  end

  it "still raises for a walk that has no reason to tolerate a missing file" do
    expect { described_class.uncommented_lines(missing) }.to raise_error(Errno::ENOENT)
  end
end

RSpec.describe "Prism parsing discipline" do
  it "routes every Prism.parse call in lib/ through AstCache" do
    lib_root = File.expand_path("../../../../lib", __FILE__)
    ast_cache_path = File.join(lib_root, "rails_ai_context", "ast_cache.rb")

    pattern = /\bPrism\.(parse|parse_file|parse_string)\b/

    offenders = DisciplineWalk.ruby_files(lib_root)
      .reject { |f| f == ast_cache_path }
      .select { |f| DisciplineWalk.uncommented_lines(f).any? { |l| l.match?(pattern) } }
      .map { |f| f.sub("#{lib_root}/", "") }

    expect(offenders).to be_empty,
      "Files calling Prism.parse* directly (must go through AstCache): #{offenders.join(', ')}"
  end
end

RSpec.describe "Prism listener registration discipline" do
  def ruby_files(root) = DisciplineWalk.ruby_files(root)

  # Only the spec half is live, so only the spec half tolerates a file that
  # went away between the glob and the read.
  def uncommented_lines(file)
    if file.start_with?("#{spec_root}/")
      DisciplineWalk.uncommented_lines_if_present(file)
    else
      DisciplineWalk.uncommented_lines(file)
    end
  end

  let(:lib_root) { File.expand_path("../../../../lib", __FILE__) }
  let(:spec_root) { File.expand_path("../../..", __FILE__) }
  # The module and its own spec are the one place a raw dispatcher is the
  # subject rather than a shortcut around it.
  let(:exempt) do
    [
      File.join(lib_root, "rails_ai_context", "introspectors", "listener_registration.rb"),
      File.join(spec_root, "lib", "rails_ai_context", "introspectors", "listener_registration_spec.rb")
    ]
  end

  it "builds every dispatcher through ListenerRegistration" do
    pattern = /\bPrism::Dispatcher\.new\b|\.register\(\s*listener/

    offenders = (ruby_files(lib_root) + ruby_files(spec_root))
      .reject { |f| exempt.include?(f) }
      .select { |f| uncommented_lines(f).any? { |l| l.match?(pattern) } }
      .map { |f| f.sub("#{File.dirname(lib_root)}/", "") }

    expect(offenders).to be_empty,
      "Files registering listeners directly (must go through ListenerRegistration): #{offenders.join(', ')}"
  end

  it "keeps the semantic visitor's visit_* overrides on names Prism::Visitor defines" do
    visitor = RailsAiContext::Tools::ValidateSemantics::RailsSemanticVisitor
    overrides = visitor.instance_methods(false).grep(/\Avisit_/)

    expect(overrides).not_to be_empty
    expect(overrides - Prism::Visitor.instance_methods).to be_empty
  end
end
