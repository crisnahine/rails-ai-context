# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Hydrators::ControllerHydrator do
  let(:context) do
    {
      models: {
        "Post" => {
          table_name: "posts",
          associations: [ { name: "user", type: "belongs_to", class_name: "User" } ],
          validations: [ { kind: "presence", attributes: [ "title" ] } ]
        },
        "Comment" => {
          table_name: "comments",
          associations: [ { name: "post", type: "belongs_to", class_name: "Post" } ],
          validations: []
        }
      },
      schema: {
        tables: {
          "posts" => {
            columns: [
              { name: "id", type: "integer", null: false },
              { name: "title", type: "string", null: false }
            ],
            primary_key: "id"
          },
          "comments" => {
            columns: [
              { name: "id", type: "integer", null: false },
              { name: "body", type: "text" }
            ],
            primary_key: "id"
          }
        }
      }
    }
  end

  let(:tmp_dir) { File.join(Dir.tmpdir, "rai_hydrator_test_#{Process.pid}") }

  before { FileUtils.mkdir_p(tmp_dir) }
  after { FileUtils.rm_rf(tmp_dir) }

  def write_controller(content)
    path = File.join(tmp_dir, "test_controller.rb")
    File.write(path, content)
    path
  end

  describe ".call" do
    it "returns schema hints for models referenced in controller" do
      path = write_controller(<<~RUBY)
        class PostsController < ApplicationController
          def show
            @post = Post.find(params[:id])
            @comments = Comment.where(post_id: @post.id)
          end
        end
      RUBY

      result = described_class.call(path, context: context)
      expect(result).to be_a(RailsAiContext::HydrationResult)
      expect(result.any?).to be true
      expect(result.hints.map(&:model_name)).to include("Post", "Comment")
    end

    it "returns empty result for nonexistent file" do
      result = described_class.call("/nonexistent/file.rb", context: context)
      expect(result.any?).to be false
    end

    it "returns empty result when no models referenced" do
      path = write_controller(<<~RUBY)
        class HealthController < ApplicationController
          def index
            render json: { status: "ok" }
          end
        end
      RUBY

      result = described_class.call(path, context: context)
      expect(result.any?).to be false
    end

    it "includes warnings for unresolved models" do
      path = write_controller(<<~RUBY)
        class PostsController < ApplicationController
          def show
            @post = Post.find(params[:id])
            @widget = Widget.first
          end
        end
      RUBY

      result = described_class.call(path, context: context)
      expect(result.hints.map(&:model_name)).to include("Post")
      expect(result.warnings).to include(match(/Widget.*not found/))
    end

    it "detects models from params.require" do
      path = write_controller(<<~RUBY)
        class PostsController < ApplicationController
          private
          def post_params
            params.require(:post).permit(:title, :body)
          end
        end
      RUBY

      result = described_class.call(path, context: context)
      expect(result.hints.map(&:model_name)).to include("Post")
    end

    it "respects hydration_max_hints configuration" do
      allow(RailsAiContext.configuration).to receive(:hydration_max_hints).and_return(1)

      path = write_controller(<<~RUBY)
        class PostsController < ApplicationController
          def show
            @post = Post.find(params[:id])
            @comments = Comment.where(post_id: @post.id)
          end
        end
      RUBY

      result = described_class.call(path, context: context)
      expect(result.hints.size).to eq(1)
    end
  end
end
