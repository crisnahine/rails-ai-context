# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::ControllerFilters do
  describe ".with_concerns" do
    def concern(dir, name, body)
      File.write(File.join(dir, "app", "controllers", "concerns", "#{name.underscore}.rb"), <<~RUBY)
        module #{name}
          extend ActiveSupport::Concern
          #{body}
        end
      RUBY
    end

    # Ruby adds a module to the ancestors once, where it is first included,
    # so a concern reached through two includes runs its filters once.
    it "adds a concern reached through two includes once, at its first include" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        concern(dir, "AccountLookup", "included do\n    before_action :set_account\n  end")
        concern(dir, "Owned", "include AccountLookup\n  included do\n    before_action :check_owner\n  end")
        source = <<~RUBY
          class PostsController < ApplicationController
            include Owned
            before_action :authenticate!
            include AccountLookup
          end
        RUBY

        filters, unread = described_class.with_concerns(source, root: dir, within: "PostsController")

        expect(filters.map { |f| [ f[:name], f[:from_concern] ] })
          .to eq([ [ "set_account", "AccountLookup" ], [ "check_owner", "Owned" ], [ "authenticate!", nil ] ])
        expect(unread).to eq([])
      end
    end

    # A macro inside a `def` runs when the method runs: never for a method nobody
    # calls, and with the call's options where the body calls it.
    it "reads a filter inside a method only where the class calls the method" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "controllers", "concerns"))
        source = <<~RUBY
          class PostsController < ApplicationController
            def self.public_actions(*names) = skip_before_action(:authenticate!, only: names)
            def self.unused = skip_before_action(:audit)
            def helper = before_action(:never)

            before_action :authenticate!
            public_actions :index, :show
          end
        RUBY

        filters, = described_class.with_concerns(source, root: dir, within: "PostsController")

        expect(filters.map { |f| [ f[:name], f[:skipped], f[:only] ] })
          .to eq([ [ "authenticate!", nil, nil ], [ "authenticate!", true, %w[index show] ] ])
        expect(described_class.from_source(source).map { |f| f[:name] }).to eq([ "authenticate!" ])
      end
    end
  end
end
