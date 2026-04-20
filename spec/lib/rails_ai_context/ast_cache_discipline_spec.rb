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
