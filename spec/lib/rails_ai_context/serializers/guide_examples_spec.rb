# frozen_string_literal: true

require "spec_helper"

# The tool guide's workflows named PostsController, app/models/post.rb and
# publishable? in every app, right beside "never reference a name you have
# not verified". An app of Authors and Books read them as its own.
RSpec.describe RailsAiContext::Serializers::GuideExamples do
  let(:library) do
    {
      models: {
        "Author" => { file: "app/models/author.rb", table_name: "authors",
                      associations: [ { type: "has_many", name: "books" } ], source_instance_methods: [] },
        "Book" => { file: "app/models/book.rb", table_name: "books",
                    associations: [ { type: "belongs_to", name: "author" }, { type: "has_many", name: "reviews" } ],
                    source_instance_methods: [ "author_name=", "in_print?" ], scopes: [ { name: "recent" } ] }
      },
      controllers: { controllers: {
        "BooksController" => { file: "app/controllers/books_controller.rb", actions: %w[index show create] },
        "Admin::AuthorsController" => { file: "app/controllers/admin/authors_controller.rb", actions: %w[index] }
      } },
      views: {
        templates: { "books" => %w[index.html.erb show.html.erb index.json.jbuilder] },
        partials: { shared: [], per_controller: { "books" => [ "_book.html.erb" ] } }
      },
      components: { components: [ { name: "RatingComponent" } ] }
    }
  end

  describe "an app with models, controllers and views of its own" do
    subject(:examples) { described_class.new(library) }

    it "names the most connected model, with its file and table" do
      expect([ examples.model, examples.model_file, examples.table, examples.feature ])
        .to eq([ "Book", "app/models/book.rb", "books", "book" ])
    end

    it "names the model's own controller and an action it has" do
      expect([ examples.controller, examples.action, examples.controller_file ])
        .to eq([ "BooksController", "create", "app/controllers/books_controller.rb" ])
    end

    it "names a template, a partial and a component the app renders" do
      expect([ examples.view_controller, examples.view_file, examples.partial, examples.component ])
        .to eq([ "books", "app/views/books/index.html.erb", "books/book", "RatingComponent" ])
    end

    it "traces a method the model's source defines, never a writer" do
      expect(examples.method_name).to eq("in_print?")
    end
  end

  it "falls back to a scope when the source defines no method" do
    library[:models]["Book"][:source_instance_methods] = []

    expect(described_class.new(library).method_name).to eq("recent")
  end

  it "takes the first controller with an action when the model has none of its own" do
    library[:controllers][:controllers].delete("BooksController")

    examples = described_class.new(library)

    expect([ examples.controller, examples.action ]).to eq([ "Admin::AuthorsController", "index" ])
  end

  it "uses placeholders no app has when there is nothing to name" do
    examples = described_class.new({})

    expect([ examples.model, examples.controller, examples.partial, examples.component, examples.method_name ])
      .to eq(%w[YourModel YourModelsController shared/your_partial YourComponent your_method])
    expect(examples.model_file).to eq("app/models/your_model.rb")
    expect(examples.view_file).to eq("app/views/your_models/index.html.erb")
  end

  it "skips a model the walk could not read" do
    library[:models]["Book"] = { error: "boom" }

    expect(described_class.new(library).model).to eq("Author")
  end

  describe "in the generated guide" do
    let(:serializer) { RailsAiContext::Serializers::ClaudeSerializer.new(serializer_context(**library)) }

    around do |example|
      RailsAiContext.configuration.context_mode = :compact
      example.run
    ensure
      RailsAiContext.configuration.context_mode = :compact
    end

    it "calls the tools with the app's own names and none of another app's" do
      output = serializer.call

      expect(output).to include('rails_get_context(model:"Book")', 'controller:"BooksController", action:"create"',
                                'files:["app/models/book.rb"]', 'pattern:"in_print?"', 'partial:"books/book"')
      expect(output).not_to match(/\bPosts?Controller\b|post\.rb|publishable\?|status_badge|UserMailer|"Button"/)
    end
  end
end
