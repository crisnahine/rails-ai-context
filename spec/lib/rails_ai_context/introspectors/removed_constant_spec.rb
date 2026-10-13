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
    allow(Post).to receive(:inheritance_column).and_return("title")
    stub_const("LivePost", Class.new(Post))
    kept = removed(:GonePost, Post)

    post = RailsAiContext::Introspectors::ModelIntrospector.new(Rails.application).call["Post"]

    expect(kept.name).to eq("GonePost")
    expect(post[:sti][:sti_children]).to eq(%w[LivePost])
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
end
