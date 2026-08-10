# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Prism parsing discipline" do
  it "routes every Prism.parse call in lib/ through AstCache" do
    lib_root = File.expand_path("../../../../lib", __FILE__)
    ast_cache_path = File.join(lib_root, "rails_ai_context", "ast_cache.rb")

    pattern = /\bPrism\.(parse|parse_file|parse_string)\b/

    offenders = Dir.glob(File.join(lib_root, "**", "*.rb"))
      .reject { |f| f == ast_cache_path }
      .select { |f|
        File.readlines(f)
          .reject { |l| l.strip.start_with?("#") }
          .any? { |l| l.match?(pattern) }
      }
      .map { |f| f.sub("#{lib_root}/", "") }

    expect(offenders).to be_empty,
      "Files calling Prism.parse* directly (must go through AstCache): #{offenders.join(', ')}"
  end
end

RSpec.describe "Prism listener registration discipline" do
  def ruby_files(root)
    Dir.glob(File.join(root, "**", "*.rb"))
  end

  def uncommented_lines(file)
    File.readlines(file).reject { |l| l.strip.start_with?("#") }
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
