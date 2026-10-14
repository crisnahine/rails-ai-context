# frozen_string_literal: true

require "spec_helper"

# Ruby keeps a class in its parent's descendants until the garbage collector takes it,
# and the class keeps the name of a constant that was removed.
RSpec.describe "a loaded class whose constant was removed" do
  def removed(name, parent, &body)
    klass = Class.new(parent, &body)
    Object.const_set(name, klass)
    Object.send(:remove_const, name)
    klass
  end

  it "is left out of the model list" do
    kept = removed(:GoneRow, ApplicationRecord)

    models = RailsAiContext::Introspectors::ModelIntrospector.new(Rails.application).call

    expect(kept.name).to eq("GoneRow")
    expect(models.keys).to include("Post")
    expect(models.keys).not_to include("GoneRow")
  end

  it "is left out of a model's STI children" do
    # The children are read where the table has the inheritance column: asked of the schema file, whatever tables the connection holds.
    allow(Post).to receive_messages(inheritance_column: "title", table_exists?: false)
    stub_const("LivePost", Class.new(Post))
    kept = removed(:GonePost, Post)

    post = RailsAiContext::Introspectors::ModelIntrospector.new(Rails.application).call["Post"]

    expect(kept.name).to eq("GonePost")
    expect(post[:sti][:sti_children]).to eq(%w[LivePost])
  end

  it "is no abstract base whose class methods are taken off a model" do
    gone = removed(:GoneBase, ActiveRecord::Base) { self.abstract_class = true }
    model = Class.new(ActiveRecord::Base) { self.table_name = "posts" }
    model.define_singleton_method(:name) { "Legacy" }
    [ gone, model ].each { |klass| klass.define_singleton_method(:recent_first) { |*| all } }

    details = RailsAiContext::Introspectors::ModelIntrospector.new(Rails.application).send(:extract_model_details, model)

    expect(details[:class_methods]).to include("recent_first")
  end

  it "is left out of the controller list" do
    kept = removed(:GoneController, ApplicationController) { def index; end }

    controllers = RailsAiContext::Introspectors::ControllerIntrospector.new(Rails.application).call[:controllers]

    expect(kept.name).to eq("GoneController")
    expect(controllers.keys).to include("PostsController")
    expect(controllers.keys).not_to include("GoneController")
  end

  it "is left out of the job, mailer and channel lists" do
    stub_const("ActionCable::Channel::Base", Class.new)
    stub_const("LiveChannel", Class.new(ActionCable::Channel::Base))
    kept = [ removed(:GoneJob, ActiveJob::Base) { def perform; end },
             removed(:GoneMailer, ActionMailer::Base) { def welcome; end },
             removed(:GoneChannel, ActionCable::Channel::Base) ]
    allow(ActionCable::Channel::Base).to receive(:descendants).and_return([ LiveChannel, kept.last ])

    found = RailsAiContext::Introspectors::JobIntrospector.new(Rails.application).call
    names = %i[jobs mailers channels].flat_map { |key| found[key].map { |entry| entry[:name] } }

    expect(kept.map(&:name)).to eq(%w[GoneJob GoneMailer GoneChannel])
    expect(names).to include("ExampleJob", "UserMailer", "LiveChannel")
    expect(names).not_to include("GoneJob", "GoneMailer", "GoneChannel")
  end

  it "makes no base of a job or a mailer it alone inherited, and is left out of the classes a base is inherited by" do
    allow(Object).to receive(:const_source_location).and_call_original
    %w[BaseSweepJob BaseNoticeMailer BaseDigestMailer LiveDigestMailer].each { |name| allow(Object).to receive(:const_source_location).with(name).and_return(nil) }
    stub_const("BaseSweepJob", Class.new(ActiveJob::Base) { def perform; end })
    stub_const("BaseNoticeMailer", Class.new(ActionMailer::Base) { def welcome; end })
    stub_const("BaseDigestMailer", Class.new(ActionMailer::Base))
    stub_const("LiveDigestMailer", Class.new(BaseDigestMailer) { def daily; end })
    kept = [ removed(:GoneSweepJob, BaseSweepJob), removed(:GoneNoticeMailer, BaseNoticeMailer), removed(:GoneDigestMailer, BaseDigestMailer) ]

    found = RailsAiContext::Introspectors::JobIntrospector.new(Rails.application).call

    expect(kept.map(&:name)).to eq(%w[GoneSweepJob GoneNoticeMailer GoneDigestMailer])
    expect(found[:jobs].map { |job| job[:name] }).to include("BaseSweepJob")
    expect(found[:mailers].map { |mailer| mailer[:name] }).to include("BaseNoticeMailer")
    expect(found[:mailer_bases].find { |base| base[:name] == "BaseDigestMailer" }).to include(inherited_by: %w[LiveDigestMailer])
  end
end
