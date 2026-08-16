# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Payload do
  describe "key pinning" do
    # Every reader's key pair, checked against what the producing
    # introspector actually emits for the static fixture app. A payload
    # rename now fails here, loudly, instead of silently emptying a section
    # in every consumer (the #144/#145 class).
    it "names only keys the producing introspector emits" do
      fixture_root = File.expand_path("../../fixtures/static_app", __dir__)
      static_app = RailsAiContext::StaticApp.new(fixture_root)

      emitted = {}
      described_class::LISTS.each do |reader, (section_key, key)|
        emitted[section_key] ||= begin
          klass = RailsAiContext::Introspector::INTROSPECTOR_MAP.fetch(section_key)
          instance = klass.new(static_app)
          result = if klass.static_tier == RailsAiContext::Introspectors::StaticTier::ALTERNATE_SOURCE
            instance.send(:static_call)
          else
            instance.call
          end
          result.keys
        end

        expect(emitted[section_key]).to include(key),
          "Payload.#{reader} reads #{section_key}[:#{key}], but the introspector emits: #{emitted[section_key].join(', ')}"
      end
    end
  end

  describe ".section" do
    it "answers the section only when it is a healthy hash" do
      expect(described_class.section({ turbo: { turbo_frames: [] } }, :turbo)).to eq({ turbo_frames: [] })
      expect(described_class.section({ turbo: { error: "boom" } }, :turbo)).to be_nil
      expect(described_class.section({ turbo: [] }, :turbo)).to be_nil
      expect(described_class.section({}, :turbo)).to be_nil
      expect(described_class.section(nil, :turbo)).to be_nil
    end
  end

  describe ".list" do
    it "always answers an array" do
      expect(described_class.list({ turbo: { turbo_frames: %w[f] } }, :turbo, :turbo_frames)).to eq(%w[f])
      expect(described_class.list({ turbo: {} }, :turbo, :turbo_frames)).to eq([])
      expect(described_class.list({}, :turbo, :turbo_frames)).to eq([])
    end
  end
  describe ".controller_route_key" do
    def ctx(file)
      { controllers: { controllers: { "InvoicesController" => { file: file } } } }
    end

    it "reads the route key from the file the controller was read from" do
      expect(described_class.controller_route_key(ctx("app/controllers/admin/invoices_controller.rb"), "InvoicesController"))
        .to eq("admin/invoices")
    end

    # A pack or an in-repo engine puts the controllers root somewhere other
    # than the start of the path, and Rails still routes by what follows it.
    it "strips a controllers root that is not at the start of the path" do
      expect(described_class.controller_route_key(ctx("packs/billing/app/controllers/invoices_controller.rb"), "InvoicesController"))
        .to eq("invoices")
    end

    # The name is all there is for a controller reflection found and the
    # filesystem did not - and it is right whenever no inflection is involved.
    it "falls back to the underscored name when no file was carried" do
      expect(described_class.controller_route_key({}, "Admin::InvoicesController")).to eq("admin/invoices")
    end
  end
end
