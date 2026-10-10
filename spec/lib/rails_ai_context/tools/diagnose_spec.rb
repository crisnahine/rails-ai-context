# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Diagnose do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "requires error parameter" do
      result = described_class.call(error: "")
      text = result.content.first[:text]
      expect(text).to include("required")
    end

    it "parses NoMethodError correctly" do
      result = described_class.call(error: "NoMethodError: undefined method `activate` for nil:NilClass")
      text = result.content.first[:text]
      expect(text).to include("NoMethodError")
      expect(text).to include("nil_reference")
      expect(text).to include("Likely Cause")
      expect(text).to include("Suggested Fix")
    end

    it "says nothing about git, and nothing on stderr, outside a repository" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post; end\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))

        text = nil
        expect {
          text = described_class.call(error: "NoMethodError: undefined method `title` for nil",
            file: "app/models/post.rb", line: 1).content.first[:text]
        }.not_to output.to_stderr_from_any_process

        expect(text).not_to include("Recent Git Changes")
      end
    end

    # A path the guard refused is an answer the reader needs to see, not an
    # empty result the composer drops.
    it "surfaces a refused file path in the composed text" do
      text = described_class.call(error: "NoMethodError: undefined method `title` for nil",
        file: "../../etc/passwd", line: 1).content.first[:text]

      expect(text).to include("Path not allowed")
    end

    [ { line: 3 }, {} ].each do |extra|
      it "refuses /etc/passwd and never suggests it#{' without a line' if extra.empty?}" do
        text = described_class.call(error: "NoMethodError: undefined method 'foo' for nil",
          file: "/etc/passwd", **extra).content.first[:text]

        expect(text).to include("Path not allowed: /etc/passwd")
        expect(text).not_to include('file:"/etc/passwd"')
      end
    end

    it "words a sensitive file's refusal as every path-taking tool does" do
      text = described_class.call(error: "NoMethodError: undefined method 'foo' for nil",
        file: "config/master.key").content.first[:text]

      expect(text).to include("Path not allowed: config/master.key (sensitive file)")
    end

    # The section promises the method's definition; a trace that only found
    # call sites is not that, and the fact comes from the answer's mark.
    it "renders no method trace when the trace found no definition" do
      text = described_class.call(
        error: "NoMethodError: undefined method `zzz_undefined_helper' for nil:NilClass"
      ).content.first[:text]

      expect(text).not_to include("## Method Trace")
    end

    it "parses ActiveRecord::RecordNotFound" do
      result = described_class.call(error: "ActiveRecord::RecordNotFound: Couldn't find User with 'id'=999")
      text = result.content.first[:text]
      expect(text).to include("record_not_found")
    end

    it "parses ActiveRecord::RecordInvalid" do
      result = described_class.call(error: "ActiveRecord::RecordInvalid: Validation failed: Name can't be blank")
      text = result.content.first[:text]
      expect(text).to include("validation_failure")
    end

    it "parses ActionController::RoutingError" do
      result = described_class.call(error: "ActionController::RoutingError: No route matches [GET] /nonexistent")
      text = result.content.first[:text]
      expect(text).to include("routing")
    end

    it "parses ParameterMissing" do
      result = described_class.call(error: "ActionController::ParameterMissing: param is missing or the value is empty: post")
      text = result.content.first[:text]
      expect(text).to include("strong_params")
    end

    it "handles unknown error types gracefully" do
      result = described_class.call(error: "SomeWeirdError happened in production")
      text = result.content.first[:text]
      expect(text).to include("Error Diagnosis")
      expect(text).not_to include("Diagnosis error")
    end

    it "extracts method name from undefined method error" do
      result = described_class.call(error: "NoMethodError: undefined method `process_payment` for nil:NilClass")
      text = result.content.first[:text]
      expect(text).to include("process_payment")
    end

    it "includes Next Steps section" do
      result = described_class.call(
        error: "NoMethodError: undefined method `foo`",
        file: "app/models/post.rb"
      )
      text = result.content.first[:text]
      expect(text).to include("Next Steps")
    end

    it "classifies NameError: uninitialized constant as name_error, not nil_reference" do
      result = described_class.call(error: "NameError: uninitialized constant MyService")
      text = result.content.first[:text]
      expect(text).to include("name_error")
      expect(text).not_to include("nil_reference")
      expect(text).to include("typo in class/module name")
      expect(text).not_to include("safe navigation")
    end

    it "classifies generic NameError as name_error" do
      result = described_class.call(error: "NameError: undefined local variable or method `foo'")
      text = result.content.first[:text]
      expect(text).to include("name_error")
      expect(text).not_to include("nil_reference")
    end

    it "still classifies NoMethodError as nil_reference" do
      result = described_class.call(error: "NoMethodError: undefined method `bar` for nil:NilClass")
      text = result.content.first[:text]
      expect(text).to include("nil_reference")
      expect(text).not_to include("name_error")
    end

    it "classifies an undefined method on a model against its real associations and columns" do
      result = described_class.call(error: "undefined method 'bogus_assoc' for an instance of Post")
      text = result.content.first[:text]
      expect(text).to include("undefined_method_on_model")
      expect(text).to include("No association/column named `bogus_assoc` on Post")
    end

    it "handles the pre-3.3 receiver-inspect NoMethodError phrasing" do
      result = described_class.call(error: "NoMethodError: undefined method `bogus_assoc' for #<Post id: 1>")
      text = result.content.first[:text]
      expect(text).to include("undefined_method_on_model")
    end

    # A receiver the message names is not nil, so "use &." was advice for
    # an error this was not.
    it "does not call a method a model has a nil reference when the model is the receiver" do
      result = described_class.call(error: "NoMethodError: undefined method `comments` for an instance of Post")
      text = result.content.first[:text]
      expect(text).to include("**Classification:** undefined_method")
      expect(text).not_to include("nil_reference")
      expect(text).not_to include("undefined_method_on_model")
    end

    it "does not call a method missing on a receiver that is not a model a nil reference" do
      result = described_class.call(error: "NoMethodError: undefined method `bogus` for an instance of SomeRandomClass")
      text = result.content.first[:text]
      expect(text).to include("**Classification:** undefined_method")
      expect(text).to include("`SomeRandomClass` has no method `bogus`")
      expect(text).not_to include("safe navigation")
    end

    it "names the method the receiver has that is closest to a typo" do
      stub_const("ReceiptSummary", Struct.new(:number, :total, keyword_init: true))

      text = described_class.call(error: "NoMethodError (undefined method 'totl' for an instance of ReceiptSummary)").content.first[:text]

      expect(text).to include("**Error:** `NoMethodError`")
      expect(text).to include("**Message:** undefined method 'totl' for an instance of ReceiptSummary")
      expect(text).to include("Did you mean `total`?")
      expect(text).to include("1. Call `total`")
    end

    it "reads a Struct receiver the way Ruby 3.2 and older print it" do
      stub_const("ReceiptSummary", Struct.new(:total))

      text = described_class.call(error: "NoMethodError: undefined method `totl' for #<struct ReceiptSummary total=3>").content.first[:text]

      expect(text).to include("Did you mean `total`?")
    end

    it "says a private method is private rather than missing" do
      text = described_class.call(error: "NoMethodError: private method 'secret' called for an instance of Post").content.first[:text]

      expect(text).to include("**Classification:** non_public_method")
      expect(text).to include("`secret` is private on `Post`")
    end

    # An exception from a gem came back as `Unknown`: the Rails log's
    # "Class (message)" shape named no class.
    it "reads the class of an error written the way a Rails log writes it" do
      text = described_class.call(error: "Pundit::AuthorizationNotPerformedError (ProductsController)").content.first[:text]

      expect(text).to include("**Error:** `Pundit::AuthorizationNotPerformedError`")
      expect(text).to include("**Message:** ProductsController")
      expect(text).to include("**Classification:** authorization_not_performed")
      expect(text).to include("verify_authorized")
    end

    it "classifies a refusal by an authorization policy" do
      text = described_class.call(error: "Pundit::NotAuthorizedError: not allowed to ProductPolicy#new? this Product").content.first[:text]

      expect(text).to include("**Classification:** authorization_denied")
    end

    it "names the gem an exception it has no rule for comes from" do
      text = described_class.call(error: "Zeitwerk::Error: wrong constant name").content.first[:text]

      expect(text).to include("**Classification:** unknown")
      expect(text).to match(/No rule here covers `Zeitwerk::Error`, which the zeitwerk gem \([\d.]+\) defines/)
    end

    it "names a locked gem after the class's namespace when nothing loaded it" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      lock = instance_double(RailsAiContext::GemLock::Spec)
      allow(lock).to receive(:present?) { |name| name == "actionpack" }
      allow(lock).to receive(:version).with("actionpack").and_return("8.1.4")
      allow(RailsAiContext::GemLock).to receive(:for).and_return(lock)

      text = described_class.call(error: "ActionController::InvalidAuthenticityToken (Can't verify CSRF token authenticity.)").content.first[:text]

      expect(text).to include("which is likely the actionpack gem's (the app's bundle locks actionpack 8.1.4)")
    end

    # The method list a model carries is capped for display. Reading it as
    # the model's complete set turned a method defined on line 36 into a
    # confident "the method does not exist", in the same answer whose Method
    # Trace printed the definition.
    context "a model with more methods than the listing carries" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          models: {
            "Post" => {
              table_name: "posts",
              associations: [],
              scopes: [],
              class_methods: [],
              instance_methods: (1..30).map { |i| "step_#{format('%02d', i)}" },
              # The model's own methods, uncapped: the display list stops at
              # thirty and `title_present?` is the thirty-second in the file.
              source_instance_methods: (1..31).map { |i| "step_#{format('%02d', i)}" } + %w[title_present?],
              instance_method_count: 132
            }
          },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } }
        )
      end

      it "does not claim a method the model's own source defines does not exist" do
        text = described_class.call(error: "NoMethodError: undefined method `title_present?' for an instance of Post").content.first[:text]

        expect(text).not_to include("undefined_method_on_model")
        expect(text).not_to include("the method does not exist")
      end

      # The reflection list is capped and attribute methods inflate its count
      # the moment anything instantiates a model, so a guard keyed on that
      # count alone switches the classification off app-wide.
      it "still names a method that is in neither the source nor the schema" do
        text = described_class.call(error: "NoMethodError: undefined method `bogus_assoc' for an instance of Post").content.first[:text]

        expect(text).to include("undefined_method_on_model")
      end
    end

    context "a model whose table_name is schema-qualified" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          models: { "Customer" => { table_name: "app.customers", associations: [], scopes: [], class_methods: [], instance_methods: [] } },
          schema: { adapter: "postgresql", adapter_source: "static_parse", tables: { "customers" => { columns: [] } } }
        )
        allow(RailsAiContext::Introspectors::SchemaIntrospector).to receive(:qualified_table)
          .and_return([ "customers", { columns: [ { name: "email", type: "string" } ] } ])
      end

      it "diagnoses against the table's columns" do
        text = described_class.call(error: "NoMethodError: undefined method `frobnicate' for an instance of Customer").content.first[:text]

        expect(text).not_to include("Diagnosis error")
        expect(text).to include("undefined_method_on_model")
      end
    end

    # A concern's methods are reflection's to report, and that list is the
    # capped one, so a model that includes concerns cannot support a negative
    # claim about a name its own file does not define.
    context "a model whose methods can come from a concern, on the static tier" do
      before do
        # No loaded class to ask: the payload is all there is.
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)
        allow(described_class).to receive(:cached_context).and_return(
          models: {
            "Post" => {
              table_name: "posts", associations: [], scopes: [], class_methods: [],
              concerns: [ "Publishable" ],
              instance_methods: (1..30).map { |i| "step_#{format('%02d', i)}" },
              source_instance_methods: (1..30).map { |i| "step_#{format('%02d', i)}" },
              instance_method_count: 132
            }
          },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } }
        )
      end

      it "declines to say the method does not exist" do
        text = described_class.call(error: "NoMethodError: undefined method `publish_later' for an instance of Post").content.first[:text]

        expect(text).not_to include("undefined_method_on_model")
      end
    end

    # Booted, the loaded class is the whole answer: it carries what the
    # payload's capped list and the model's own file cannot, a concern's
    # methods and a gem's included.
    context "a booted app whose model class is loaded" do
      let(:truncated_post) do
        {
          table_name: "posts", associations: [], scopes: [], class_methods: [],
          concerns: [ "Publishable" ],
          instance_methods: (1..30).map { |i| "step_#{format('%02d', i)}" },
          source_instance_methods: %w[display_url],
          instance_method_count: 132
        }
      end

      it "still names a real typo on a model whose list was cut" do
        allow(described_class).to receive(:cached_context).and_return(
          models: { "Post" => truncated_post },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } }
        )

        text = described_class.call(error: "NoMethodError: undefined method `nope_xyz' for an instance of Post").content.first[:text]

        expect(text).to include("undefined_method_on_model")
      end

      # `to_param` comes from ActiveRecord, is in no payload list, and exists
      # on every model: the negative claim read "the method does not exist".
      it "does not claim a method the loaded class defines is missing" do
        allow(described_class).to receive(:cached_context).and_return(
          models: { "Post" => truncated_post.merge(concerns: [], instance_method_count: 30) },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } }
        )

        text = described_class.call(error: "NoMethodError: undefined method `to_param' for an instance of Post").content.first[:text]

        expect(text).not_to include("undefined_method_on_model")
      end
    end

    # A context written before the source list existed carries no key for it,
    # and a negative claim cannot be read off what is left.
    context "a payload from before the source method list existed, on the static tier" do
      before do
        allow(RailsAiContext).to receive(:static_tier?).and_return(true)
        allow(described_class).to receive(:cached_context).and_return(
          models: {
            "Post" => {
              table_name: "posts", associations: [], scopes: [], class_methods: [],
              instance_methods: (1..30).map { |i| "step_#{format('%02d', i)}" },
              instance_method_count: 32
            }
          },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } }
        )
      end

      it "declines to classify rather than guess" do
        text = described_class.call(error: "NoMethodError: undefined method `title_present?' for an instance of Post").content.first[:text]

        expect(text).not_to include("undefined_method_on_model")
      end
    end

    context "a model whose method list is complete" do
      before do
        allow(described_class).to receive(:cached_context).and_return(
          models: {
            "Post" => {
              table_name: "posts",
              associations: [],
              scopes: [],
              class_methods: [],
              instance_methods: %w[title_present?],
              instance_method_count: 1
            }
          },
          schema: { tables: { "posts" => { columns: [ { name: "title", type: "string" } ] } } }
        )
      end

      it "still names a method the model really does not define" do
        text = described_class.call(error: "NoMethodError: undefined method `bogus_assoc' for an instance of Post").content.first[:text]

        expect(text).to include("undefined_method_on_model")
      end
    end

    it "truncates oversized output to within MAX_TOTAL_OUTPUT" do
      # Stub gather_context to return a very large section
      allow(described_class).to receive(:gather_context).and_return(
        [ "## Controller Context", "x" * 50_000, "" ]
      )
      allow(described_class).to receive(:gather_git_context).and_return([])
      allow(described_class).to receive(:gather_log_context).and_return([])

      result = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass")
      text = result.content.first[:text]
      # The total output should not exceed MAX_TOTAL_OUTPUT + the truncation message
      expect(text.length).to be <= 20_200
      expect(text).to include("truncated")
    end

    it "truncates individual sections exceeding their max" do
      large_content = "y" * 5_000
      allow(described_class).to receive(:gather_context).and_return(
        [ "## Controller Context", large_content, "" ]
      )
      allow(described_class).to receive(:gather_git_context).and_return([])
      allow(described_class).to receive(:gather_log_context).and_return([])

      result = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass")
      text = result.content.first[:text]
      # The controller context section should be truncated to ~3000 chars
      expect(text).to include("section truncated")
      expect(text).not_to include(large_content)
    end
    # A sub-tool that raises is an answer the reader needs: the section still
    # renders, carrying the reason it is empty.
    it "renders the failure reason when the controller sub-tool raises" do
      allow(RailsAiContext::Tools::GetControllers).to receive(:call).and_raise("boom")

      text = described_class.call(error: "NoMethodError: undefined method `foo` for nil:NilClass",
        action: "posts#show").content.first[:text]

      expect(text).to include("## Controller Context")
      expect(text).to include("_Could not load: boom_")
    end

    it "renders the failure reason when the edit-context sub-tool raises" do
      allow(RailsAiContext::Tools::GetEditContext).to receive(:call).and_raise("kaboom")

      text = described_class.call(error: "NoMethodError: undefined method `title` for nil",
        file: "app/models/post.rb", line: 1).content.first[:text]

      expect(text).to include("## Code Context")
      expect(text).to include("_Could not load: kaboom_")
    end

    # The schema, model and trace steps are best-effort: a raise leaves the
    # section out entirely and says so only under DEBUG.
    context "a schema_mismatch error whose table the schema payload holds" do
      let(:schema_error) do
        "ActiveRecord::StatementInvalid: PG::UndefinedColumn: ERROR: relation \"widgets\" does not exist"
      end

      before do
        RailsAiContext::Tools::GetSchema.reset_cache!
        allow(RailsAiContext::Tools::GetSchema).to receive(:cached_context).and_return(
          schema: {
            adapter: "postgresql",
            total_tables: 1,
            tables: {
              "widgets" => {
                columns: [ { name: "id", type: "integer", null: false }, { name: "sku", type: "string", null: true } ],
                indexes: [],
                foreign_keys: []
              }
            }
          },
          models: {}
        )
      end

      it "renders the schema section" do
        text = described_class.call(error: schema_error).content.first[:text]

        expect(text).to include("## Schema Context")
        expect(text).to include("sku")
      end

      it "drops the schema section when its sub-tool raises" do
        allow(RailsAiContext::Tools::GetSchema).to receive(:call).and_raise("nope")

        text = described_class.call(error: schema_error).content.first[:text]

        expect(text).not_to include("## Schema Context")
        expect(text).not_to include("Could not load: nope")
      end
    end
  end

  # Fifteen lines of the log were read, so an error older than the last few
  # requests was never found, and a match printed the matching line alone.
  describe "log correlation" do
    let(:root) { Dir.mktmpdir }
    let(:tag) { "[6c1c9afa-e592-456c-a41a-21129b7866be]" }

    before do
      FileUtils.mkdir_p(File.join(root, "log"))
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
      allow(described_class).to receive(:rails_env_name).and_return("development")
    end

    after { FileUtils.rm_rf(root) }

    def write_log(lines)
      File.write(File.join(root, "log", "development.log"), lines.join("\n") + "\n")
    end

    def log_section(error)
      described_class.call(error: error).content.first[:text][/## Recent Error Logs.*/m]
    end

    let(:later_requests) { Array.new(200) { |i| %(Started GET "/up" for 127.0.0.1 at 2026-10-10 14:00:#{i % 60} +0000) } }

    it "shows the request that raised it, however far back, without its request-id tag" do
      write_log([
        %(#{tag} Started GET "/orders/3/receipt" for 127.0.0.1 at 2026-10-10 13:59:13 +0000),
        "#{tag} Processing by OrdersController#receipt as */*",
        %(#{tag}   Parameters: {"id"=>"3"}),
        %(#{tag}   Order Load (0.8ms)  SELECT "orders".* FROM "orders" WHERE "orders"."id" = 3),
        "#{tag} Completed 500 Internal Server Error in 42ms (ActiveRecord: 6.4ms)",
        "#{tag}   ",
        "#{tag} NoMethodError (undefined method `totl' for an instance of ReceiptPresenter::Summary):",
        "#{tag}   ",
        "#{tag} app/controllers/orders_controller.rb:30:in `receipt'",
        *later_requests
      ])

      section = log_section("NoMethodError: undefined method 'totl' for an instance of ReceiptPresenter::Summary")

      expect(section).to include("request `6c1c9afa-e592-456c-a41a-21129b7866be`")
      expect(section).to include(<<~TEXT)
        ```
        Started GET "/orders/3/receipt" for 127.0.0.1 at 2026-10-10 13:59:13 +0000
        Processing by OrdersController#receipt as */*
          Parameters: {"id"=>"3"}
        Completed 500 Internal Server Error in 42ms (ActiveRecord: 6.4ms)
        NoMethodError (undefined method `totl' for an instance of ReceiptPresenter::Summary):
        app/controllers/orders_controller.rb:30:in `receipt'
        ```
      TEXT
    end

    it "finds the request in a log that writes no tags" do
      write_log([
        %(Started GET "/products/featured?q=x" for 127.0.0.1 at 2026-10-10 14:49:26 +0000),
        "Processing by ProductsController#featured as */*",
        %(  Parameters: {"q"=>"x"}),
        "Completed 500 Internal Server Error in 119ms",
        "",
        "Pundit::AuthorizationNotPerformedError (ProductsController):",
        "",
        "pundit (2.5.2) lib/pundit/authorization.rb:127:in `verify_authorized'",
        *later_requests
      ])

      section = log_section("Pundit::AuthorizationNotPerformedError (ProductsController)")

      expect(section).to include(%(Processing by ProductsController#featured as */*\n  Parameters: {"q"=>"x"}))
      expect(section).to include("Pundit::AuthorizationNotPerformedError (ProductsController):\npundit (2.5.2) lib/pundit/authorization.rb:127")
      expect(section).not_to include("request `")
    end

    it "says when the log holds no entry for it" do
      write_log(later_requests)

      expect(log_section("Pundit::NotAuthorizedError: not allowed")).to include("_No entry for `Pundit::NotAuthorizedError` in the last 200 lines of `log/development.log`._")
    end

    it "names an entry it could not redact rather than printing it" do
      write_log([ "Pundit::NotAuthorizedError (not allowed to ProductPolicy#new? this Product):" ])
      allow(RailsAiContext::Redaction).to receive(:redact_log_lines).and_raise(RegexpError, "invalid pattern in look-behind")

      section = log_section("Pundit::NotAuthorizedError: not allowed to ProductPolicy#new? this Product")

      expect(section).to include("not shown: redacting it failed (RegexpError)")
      expect(section).not_to include("ProductPolicy")
    end
  end

  describe "a model whose table lives in a secondary database" do
    it "counts the table's columns as known names" do
      allow(described_class).to receive(:cached_context).and_return(
        schema: { tables: {}, secondary_databases: { "analytics" => { tables: { "page_views" => { columns: [ { name: "path", type: "string" } ] } } } } }
      )
      expect(described_class.send(:known_model_methods, { table_name: "page_views" })).to include("path")
    end
  end
end
