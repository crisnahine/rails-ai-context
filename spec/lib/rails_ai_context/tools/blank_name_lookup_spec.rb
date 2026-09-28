# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# A blank name is not a name. It matched Discourse's
# plugins/.../app/helpers/helper.rb through the `_helper` basename probe and
# crashed on the empty path it left; elsewhere it was looked up as if it were
# one. Every by-name lookup answers it up front, the same way.
RSpec.describe "a blank name given to a by-name lookup" do
  let(:tmpdir) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(tmpdir, "app", "helpers"))
    File.write(File.join(tmpdir, "app", "helpers", "helper.rb"), "module Helper\n  def shout(text) = text.upcase\nend\n")
    FileUtils.mkdir_p(File.join(tmpdir, "app", "services"))
    File.write(File.join(tmpdir, "app", "services", "notify_service.rb"), "class NotifyService\n  def call; end\nend\n")
    allow(Rails.application).to receive(:root).and_return(Pathname.new(tmpdir))
    RailsAiContext::Tools::BaseTool.reset_all_caches! if RailsAiContext::Tools::BaseTool.respond_to?(:reset_all_caches!)
  end

  after { FileUtils.remove_entry(tmpdir) }

  # The answer names what the tool looks up, so a parameter called `name`
  # does not read "The `name` name is blank."
  {
    RailsAiContext::Tools::GetHelperMethods => [ :helper, "helper" ],
    RailsAiContext::Tools::GetServicePattern => [ :service, "service" ],
    RailsAiContext::Tools::GetJobPattern => [ :job, "job" ],
    RailsAiContext::Tools::GetMailers => [ :mailer, "mailer" ],
    RailsAiContext::Tools::GetComponentCatalog => [ :component, "component" ],
    RailsAiContext::Tools::GetConcern => [ :name, "concern" ]
  }.each do |tool, (param, kind)|
    [ "", "   " ].each do |blank|
      it "#{tool.tool_name} answers #{param}: #{blank.inspect} as blank" do
        tool.reset_cache!

        text = tool.call(**{ param => blank }).content.first[:text]

        expect(text).to eq("The #{kind} name is blank. Give one, or omit `#{param}` to list them all.")
      end
    end
  end
end
