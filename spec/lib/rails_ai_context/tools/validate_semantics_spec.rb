# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The one tool file that had no spec of its own. These drive the dispatcher
# through its public seam; the rules gain coverage as they change.
RSpec.describe RailsAiContext::Tools::ValidateSemantics do
  def with_app_file(relative, content)
    Dir.mktmpdir do |root|
      full = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      yield relative, full
    end
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({
      routes: { by_controller: {} },
      schema: { tables: {} },
      models: {}
    })
  end

  describe ".check_rails_semantics" do
    it "answers cleanly for a plain file" do
      with_app_file("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n") do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings).to eq([])
      end
    end

    it "says which checks were skipped when the AST parse fails, instead of reading as clean" do
      allow(RailsAiContext::AstCache).to receive(:parse_string).and_raise(RuntimeError, "prism exploded")

      with_app_file("app/models/widget.rb", "class Widget < ApplicationRecord\nend\n") do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings.join).to include("AST parse failed")
        expect(warnings.join).to include("skipped")
      end
    end

    it "flags a scope chain that loads every record into memory" do
      source = <<~RUBY
        class WidgetsController < ApplicationController
          def index
            @names = Widget.active.map { |w| w.name }
          end
        end
      RUBY

      with_app_file("app/controllers/widgets_controller.rb", source) do |file, path|
        warnings = described_class.check_rails_semantics(file, path)
        expect(warnings.join).to include("may load all records into memory")
      end
    end
  end
end
