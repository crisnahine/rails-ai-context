# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::ActionOutcome do
  def outcome(body, helpers = "", format: :html, verb: "get")
    tree = Prism.parse("class C\n  def act\n#{body}\n  end\n#{helpers}\nend\n").value
    defs = RailsAiContext::Introspectors::AstWalk.each(tree).grep(Prism::DefNode).to_h { |node| [ node.name, node ] }
    described_class.of(defs[:act], defs, format: format, verb: verb)
  end

  it "reads an empty action as the implicit render" do
    expect(outcome("")).to eq(kind: :render)
  end

  it "reads an unconditional redirect, and names a literal target" do
    expect(outcome('redirect_to "/login", flash: { notice: "x" }')).to eq(kind: :redirect, target: '"/login"')
    expect(outcome("redirect_to root_path")).to eq(kind: :redirect, target: "root_path")
  end

  it "leaves a target built from a record unnamed" do
    expect(outcome("redirect_to @user.path")).to eq(kind: :redirect)
  end

  it "reads a redirect after a condition that answers nothing" do
    expect(outcome("flash[:x] = 1 if params[:y]\nredirect_to \"/\"")).to eq(kind: :redirect, target: '"/"')
  end

  it "reads branches that all redirect as a redirect" do
    expect(outcome("if @a\n  redirect_to a_path\nelse\n  redirect_to b_path\nend")).to eq(kind: :redirect)
  end

  it "reads branches that answer differently as conditional" do
    expect(outcome("if @user\n  redirect_to @user\nelse\n  raise ActiveRecord::RecordNotFound\nend")).to eq(kind: :conditional)
    expect(outcome("redirect_to root_path unless current_user")).to eq(kind: :conditional)
  end

  it "reads an answer inside a block as conditional" do
    expect(outcome("respond_to do |format|\n  format.json { render json: {} }\nend")).to eq(kind: :conditional)
  end

  it "reads head, render json and render plain" do
    expect(outcome("head :no_content")).to eq(kind: :head, status: :no_content)
    expect(outcome("render json: { a: 1 }")).to eq(kind: :json, content_type: "application/json")
    expect(outcome("render plain: \"ok\", status: :accepted")).to eq(kind: :plain, status: :accepted, content_type: "text/plain")
  end

  # Whitehall's show calls fetch_version_and_remark_trails, which only loads
  # records: calling a helper is no answer unless the helper gives one.
  it "reads a helper that answers nothing as no answer" do
    helper = "  def load_trails\n    @trails = Trail.all\n  end"
    expect(outcome("load_trails\n@x = if a then b else c end", helper)).to eq(kind: :render)
  end

  it "reads a helper that answers under a condition as conditional" do
    helper = "  def require_admin\n    redirect_to root_path unless admin?\n  end"
    expect(outcome("require_admin", helper)).to eq(kind: :conditional)
  end

  # An API can render its JSON with `render plain:, content_type: "application/json"`.
  it "takes the media type from a literal content_type, and names none for a computed one" do
    expect(outcome("render plain: body, content_type: \"application/json\"")).to eq(kind: :plain, content_type: "application/json")
    expect(outcome("render plain: body, content_type: type")).to eq(kind: :plain, content_type: :unknown)
  end

  # The scaffold splits on the save; the test sends valid params.
  it "reads the branch a successful save takes, and says it assumed one" do
    body = "if @post.save\n  render json: @post, status: :created\nelse\n  render json: @post.errors, status: :unprocessable_entity\nend"
    expect(outcome(body)).to eq(kind: :json, status: :created, content_type: "application/json", assumed_valid: true)
    expect(outcome("unless @post.update(post_params)\n  render :edit\nelse\n  redirect_to posts_path\nend"))
      .to eq(kind: :redirect, target: "posts_path", assumed_valid: true)
  end

  it "reads the respond_to block for the format the test requests" do
    body = "respond_to do |format|\n  format.html { redirect_to posts_path }\n  format.json { head :no_content }\nend"
    expect(outcome(body)).to eq(kind: :redirect, target: "posts_path")
    expect(outcome(body, format: :json)).to eq(kind: :head, status: :no_content)
  end

  it "reads a redirect's literal status" do
    expect(outcome("redirect_to posts_path, status: :see_other")).to eq(kind: :redirect, status: :see_other, target: "posts_path")
  end

  it "reads a helper that answers from inside a block as conditional" do
    helper = "  def go_home\n    redirect_to root_path\n  end"
    expect(outcome("items.each { |item| go_home if item.gone? }", helper)).to eq(kind: :conditional)
  end

  # The responders gem answers respond_with by format and verb: an HTML
  # write redirects, a JSON create is 201 and a JSON update or destroy 204,
  # and a read renders. The test sends valid params.
  describe "respond_with" do
    it "answers an HTML write with a redirect and an HTML read with a render" do
      expect(outcome("@note = Note.create(note_params)\nrespond_with @note", verb: "post"))
        .to eq(kind: :redirect, assumed_valid: true)
      expect(outcome("respond_with @notes")).to eq(kind: :render)
    end

    it "answers a JSON create with 201 and a JSON update or destroy with 204" do
      expect(outcome("respond_with @note", format: :json, verb: "post"))
        .to eq(kind: :json, status: :created, content_type: "application/json", assumed_valid: true)
      expect(outcome("respond_with @note", format: :json, verb: "patch")).to eq(kind: :head, status: :no_content, assumed_valid: true)
      expect(outcome("respond_with @note", format: :json, verb: "delete")).to eq(kind: :head, status: :no_content, assumed_valid: true)
      expect(outcome("respond_with @notes", format: :json)).to eq(kind: :json, content_type: "application/json")
    end

    it "reads a respond_with that takes a block as conditional" do
      expect(outcome("respond_with(@note) { |format| format.html { redirect_to root_path } }", verb: "post")).to eq(kind: :conditional)
    end
  end

  # A guard that returns renders implicitly; the test may take either path.
  describe "an early return" do
    it "reads a guarded return before a redirect as conditional" do
      expect(outcome("return unless params[:x]\nredirect_to root_path")).to eq(kind: :conditional)
      expect(outcome("if params[:x]\n  flash[:a] = 1\n  return\nend\nredirect_to root_path")).to eq(kind: :conditional)
    end

    it "reads an unconditional return as the implicit render" do
      expect(outcome("return\nredirect_to root_path")).to eq(kind: :render)
    end

    it "reads the answer a return carries" do
      expect(outcome("return redirect_to(root_path)")).to eq(kind: :redirect, target: "root_path")
      expect(outcome("redirect_to root_path and return\nrender :x")).to eq(kind: :redirect, target: "root_path")
    end
  end

  it "follows a helper the action calls" do
    expect(outcome("go_home", "  def go_home\n    redirect_to root_path\n  end")).to eq(kind: :redirect, target: "root_path")
  end
end
