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
  end
end
