# Prism AST Migration - Full Regex-to-AST Conversion

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every regex-based source file scan in all 31 introspectors with Prism AST-based extraction, using the existing AstCache + Dispatcher + Listener architecture.

**Architecture:** Extend `SourceIntrospector` with a generic `walk(path, listener_map)` API that accepts any combination of listeners. Create new listener classes for patterns not covered by the existing 7 listeners. Each introspector replaces its regex scanning with AST walks, keeping runtime reflection and non-Ruby file parsing as-is. Output formats remain identical so all 2116 existing tests pass without modification.

**Tech Stack:** Prism (Ruby parser, stdlib in 3.3+), Prism::Dispatcher (single-pass AST event system), RSpec, Combustion

**Baseline:** 2116 examples, 0 failures. Every phase must maintain this.

---

## Master Roadmap

| Phase | Scope | New Listeners | Introspectors Converted | Est. Tasks |
|-------|-------|---------------|------------------------|------------|
| 1 | Infrastructure + Simple Macros | ChainedCallListener | ActiveStorage, ActionText, ActionMailbox | 6 |
| 2 | Controller Patterns | FilterListener, StrongParamsListener, ControllerMacroListener | Controller, Security (ctrl), Auth (ctrl) | 7 |
| 3 | Initializer/Config Patterns | ConfigAssignmentListener, PolicyDirectiveListener, MiddlewareConfigListener | Security (init), Middleware, Auth (init), Autoload | 6 |
| 4 | Model Pattern Extensions | DeviseListener, MultiDbListener, ConventionMacroListener | Auth (model), MultiDatabase, Convention | 5 |
| 5 | DSL File Patterns | MigrationDslListener, SchemaDslListener, GemfileDslListener, RakeTaskDslListener, MountListener | Migration, Schema, Gem, RakeTask, Engine, AssetPipeline | 8 |
| 6 | Miscellaneous | EnvAccessListener, SeedPatternListener, PumaConfigListener | Env, Seeds, DevOps, Api, Performance, Test | 8 |
| 7 | View/Component Patterns | ComponentStructureListener, PartialRenderListener, TurboViewListener | Component, View, ViewTemplate, Turbo, Stimulus, FrontendFramework | 7 |
| 8 | Cleanup + Integration | (none) | ActiveSupport, Config, remaining hybrids | 4 |

**Total: ~51 tasks across 8 phases.**

### What stays as-is (not convertible to Prism)

These patterns use non-Ruby files or runtime reflection. AST does not apply:

| Pattern | Reason | Introspectors |
|---------|--------|---------------|
| Gemfile.lock parsing | Bundler format, not Ruby | Gem, Auth (gem_present?), Convention |
| YAML file parsing | database.yml, storage.yml, locales, sidekiq.yml, etc. | Config, I18n, ActiveStorage, MultiDatabase, DevOps |
| JSON file parsing | package.json, tsconfig.json | FrontendFramework, AssetPipeline |
| ERB/Haml template markup | `<%= %>` is not pure Ruby | View, ViewTemplate, Turbo, Stimulus |
| JS/TS file scanning | Prism parses Ruby only | Stimulus, ActionText (Trix), FrontendFramework |
| .env file parsing | Not Ruby | Env |
| Procfile/Dockerfile | Not Ruby | DevOps |
| Runtime reflection | `app.config.*`, `ActiveRecord::Base.*`, etc. | All introspectors with runtime queries |
| `app.middleware` stack | Runtime Rack stack | Middleware, Config |
| `app.routes` | Runtime route table | Route |
| DB queries (pg_stat, etc.) | SQL, not Ruby | DatabaseStats, ConnectionPool |

---

## Phase 1: Infrastructure + Simple Macro Conversions

### Task 1: Add SourceIntrospector.walk API

**Files:**
- Modify: `lib/rails_ai_context/introspectors/source_introspector.rb`
- Test: `spec/lib/rails_ai_context/introspectors/source_introspector_spec.rb`

- [ ] **Step 1: Write failing test for `walk_source` with custom listener map**

Add to `source_introspector_spec.rb`:

```ruby
describe ".walk_source" do
  it "accepts a custom listener map and returns keyed results" do
    source = <<~RUBY
      class User < ApplicationRecord
        has_many :posts
        encrypts :ssn
      end
    RUBY

    result = described_class.walk_source(source, {
      associations: RailsAiContext::Introspectors::Listeners::AssociationsListener,
      macros: RailsAiContext::Introspectors::Listeners::MacrosListener
    })

    expect(result).to have_key(:associations)
    expect(result).to have_key(:macros)
    expect(result[:associations].first[:name]).to eq(:posts)
    expect(result[:macros].first[:macro]).to eq(:encrypts)
  end

  it "does not include listeners not in the map" do
    source = "class X < ApplicationRecord; has_many :items; end"
    result = described_class.walk_source(source, {
      macros: RailsAiContext::Introspectors::Listeners::MacrosListener
    })

    expect(result).to have_key(:macros)
    expect(result).not_to have_key(:associations)
  end
end

describe ".walk" do
  it "parses a file path with a custom listener map" do
    path = File.join(Rails.root, "app/models/user.rb")
    result = described_class.walk(path, {
      associations: RailsAiContext::Introspectors::Listeners::AssociationsListener
    })

    expect(result[:associations]).to be_an(Array)
    expect(result[:associations]).not_to be_empty
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/source_introspector_spec.rb -e "walk"`
Expected: FAIL with `NoMethodError: undefined method 'walk_source'`

- [ ] **Step 3: Implement walk, walk_source, walk_dispatch**

In `source_introspector.rb`, add three public class methods and extract `walk_dispatch` from existing `dispatch`:

```ruby
def self.walk(path, listener_map = LISTENER_MAP)
  result = AstCache.parse(path)
  walk_dispatch(result, listener_map)
end

def self.walk_source(source, listener_map = LISTENER_MAP)
  result = AstCache.parse_string(source)
  walk_dispatch(result, listener_map)
end

def self.walk_dispatch(parse_result, listener_map)
  dispatcher = Prism::Dispatcher.new
  listeners = listener_map.transform_values { |klass|
    listener = klass.new
    register_listener(dispatcher, listener)
    listener
  }

  dispatcher.dispatch(parse_result.value)
  listeners.transform_values(&:results)
rescue => e
  $stderr.puts "[rails-ai-context] SourceIntrospector walk_dispatch failed: #{e.message}" if ENV["DEBUG"]
  listener_map.keys.each_with_object({}) { |key, h| h[key] = [] }
end
```

Refactor existing `dispatch` to delegate to `walk_dispatch`:

```ruby
def self.dispatch(parse_result)
  walk_dispatch(parse_result, LISTENER_MAP)
end
```

Keep `register_listener` as `private_class_method` - it's already shared.

- [ ] **Step 4: Run tests to verify pass**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/source_introspector_spec.rb`
Expected: ALL PASS (existing + new)

- [ ] **Step 5: Verify full suite still passes**

Run: `bundle exec rspec spec/lib/`
Expected: 2116 examples, 0 failures

- [ ] **Step 6: Commit**

```bash
git add lib/rails_ai_context/introspectors/source_introspector.rb spec/lib/rails_ai_context/introspectors/source_introspector_spec.rb
git commit -m "feat: add SourceIntrospector.walk API for generic AST walking with custom listener maps"
```

---

### Task 2: Create ChainedCallListener

A configurable listener for method calls WITH receivers (e.g., `.variant(:thumb)`, `.includes(:posts)`). Complements existing listeners which only match receiver-less calls.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/chained_call_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/chained_call_listener_spec.rb`

- [ ] **Step 1: Write failing test**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::ChainedCallListener do
  def parse_and_dispatch(source, *methods)
    result = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener = described_class.new(*methods)
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects method calls with receivers" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      class User < ApplicationRecord
        def thumb
          avatar.variant(:thumb, resize_to_limit: [100, 100])
        end
      end
    RUBY

    expect(results.size).to eq(1)
    expect(results.first[:method]).to eq("variant")
    expect(results.first[:args]).to eq([:thumb])
  end

  it "ignores receiver-less calls" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      variant(:thumb)
    RUBY

    expect(results).to be_empty
  end

  it "filters by target method names" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      image.variant(:thumb)
      image.purge
      image.url
    RUBY

    expect(results.size).to eq(1)
    expect(results.first[:method]).to eq("variant")
  end

  it "extracts keyword options" do
    results = parse_and_dispatch(<<~RUBY, :variant)
      avatar.variant(:thumb, resize_to_limit: [100, 100])
    RUBY

    expect(results.first[:options]).to have_key(:resize_to_limit)
  end

  it "accepts multiple target methods" do
    results = parse_and_dispatch(<<~RUBY, :variant, :includes)
      avatar.variant(:thumb)
      Post.includes(:comments)
    RUBY

    expect(results.size).to eq(2)
    methods = results.map { |r| r[:method] }
    expect(methods).to contain_exactly("variant", "includes")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/listeners/chained_call_listener_spec.rb`
Expected: FAIL - class does not exist

- [ ] **Step 3: Implement ChainedCallListener**

```ruby
# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class ChainedCallListener < BaseListener
        def initialize(*methods)
          super()
          @target_methods = methods.flatten.map(&:to_sym).to_set
        end

        def on_call_node_enter(node)
          return if node.receiver.nil?
          return unless @target_methods.include?(node.name)

          @results << {
            method:   node.name.to_s,
            args:     extract_symbol_args(node),
            options:  extract_keyword_options(node),
            location: node.location.start_line
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/listeners/chained_call_listener_spec.rb`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rails_ai_context/introspectors/listeners/chained_call_listener.rb spec/lib/rails_ai_context/introspectors/listeners/chained_call_listener_spec.rb
git commit -m "feat: add ChainedCallListener for method-on-receiver AST patterns"
```

---

### Task 3: Convert ActiveStorageIntrospector to AST

Replace three regex methods: `extract_attachments`, `extract_attachment_validations`, `extract_variants`.

**Files:**
- Modify: `lib/rails_ai_context/introspectors/active_storage_introspector.rb`
- Modify: `spec/lib/rails_ai_context/introspectors/active_storage_introspector_spec.rb`

- [ ] **Step 1: Verify baseline**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/active_storage_introspector_spec.rb`
Expected: ALL PASS

- [ ] **Step 2: Write failing test for AST-based variant detection**

Add to spec:

```ruby
context "with variants defined in model source" do
  let(:fixture_model) { File.join(Rails.root, "app/models/document.rb") }

  before do
    File.write(fixture_model, <<~RUBY)
      class Document < ApplicationRecord
        has_one_attached :file
        has_many_attached :images

        def thumbnail
          file.variant(:thumb, resize_to_limit: [100, 100])
        end
      end
    RUBY
  end

  after { FileUtils.rm_f(fixture_model) }

  it "detects variant names via AST" do
    variants = result[:variants]
    expect(variants).to include(a_hash_including(model: "Document", name: "thumb"))
  end

  it "detects attachment macros via AST" do
    attachments = result[:attachments].select { |a| a[:model] == "Document" }
    types = attachments.map { |a| a[:type] }
    expect(types).to include("has_one_attached", "has_many_attached")
  end
end
```

- [ ] **Step 3: Run test to verify it passes with current regex (baseline compatibility)**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/active_storage_introspector_spec.rb`
Expected: PASS (regex already handles these patterns)

- [ ] **Step 4: Replace `extract_attachments` with AST**

```ruby
def extract_attachments
  models_dir = File.join(root, "app/models")
  return [] unless Dir.exist?(models_dir)

  attachments = []
  Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
    model_name = File.basename(path, ".rb").camelize
    ast_data = SourceIntrospector.walk(path, { macros: Listeners::MacrosListener })
    ast_data[:macros].each do |m|
      next unless %i[has_one_attached has_many_attached].include?(m[:macro])
      attachments << { model: model_name, name: m[:attribute], type: m[:macro].to_s }
    end
  end

  attachments.sort_by { |a| [a[:model], a[:name]] }
rescue => e
  $stderr.puts "[rails-ai-context] extract_attachments failed: #{e.message}" if ENV["DEBUG"]
  []
end
```

- [ ] **Step 5: Replace `extract_attachment_validations` with AST**

```ruby
def extract_attachment_validations
  validations = []
  models_dir = File.join(app.root, "app", "models")
  return validations unless Dir.exist?(models_dir)

  Dir.glob(File.join(models_dir, "**", "*.rb")).each do |path|
    model = File.basename(path, ".rb").camelize
    ast_data = SourceIntrospector.walk(path, { validations: Listeners::ValidationsListener })
    ast_data[:validations].each do |v|
      v[:attributes].each do |attr|
        validations << { model: model, attachment: attr, type: "content_type" } if v[:options].key?(:content_type)
        validations << { model: model, attachment: attr, type: "size" } if v[:options].key?(:size)
      end
    end
  end
  validations
rescue => e
  $stderr.puts "[rails-ai-context] extract_attachment_validations failed: #{e.message}" if ENV["DEBUG"]
  []
end
```

- [ ] **Step 6: Replace `extract_variants` with AST using ChainedCallListener**

The `walk` API instantiates listener classes via `.new`. ChainedCallListener needs constructor args. Create a subclass:

Add to `chained_call_listener.rb`:

```ruby
class VariantCallListener < ChainedCallListener
  def initialize
    super(:variant)
  end
end
```

Then replace the method:

```ruby
def extract_variants
  variants = []
  models_dir = File.join(app.root, "app", "models")
  return variants unless Dir.exist?(models_dir)

  Dir.glob(File.join(models_dir, "**", "*.rb")).each do |path|
    model = File.basename(path, ".rb").camelize
    ast_data = SourceIntrospector.walk(path, { variants: Listeners::VariantCallListener })
    ast_data[:variants].each do |v|
      v[:args].each do |name|
        variants << { model: model, name: name.to_s }
      end
    end
  end
  variants
rescue => e
  $stderr.puts "[rails-ai-context] extract_variants failed: #{e.message}" if ENV["DEBUG"]
  []
end
```

- [ ] **Step 7: Run all tests to verify pass**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/active_storage_introspector_spec.rb`
Expected: ALL PASS

Run: `bundle exec rspec spec/lib/`
Expected: 2116+ examples, 0 failures

- [ ] **Step 8: Commit**

```bash
git add lib/rails_ai_context/introspectors/active_storage_introspector.rb lib/rails_ai_context/introspectors/listeners/chained_call_listener.rb spec/lib/rails_ai_context/introspectors/active_storage_introspector_spec.rb
git commit -m "refactor: convert ActiveStorageIntrospector from regex to Prism AST"
```

---

### Task 4: Convert ActionTextIntrospector to AST

Replace `extract_rich_text_fields` regex with MacrosListener. `detect_trix_customizations` scans JS files - stays as-is.

**Files:**
- Modify: `lib/rails_ai_context/introspectors/action_text_introspector.rb`
- Modify: `spec/lib/rails_ai_context/introspectors/action_text_introspector_spec.rb`

- [ ] **Step 1: Verify baseline**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/action_text_introspector_spec.rb`
Expected: ALL PASS

- [ ] **Step 2: Write failing test for AST-based rich text detection**

Add to spec:

```ruby
context "with has_rich_text in a model" do
  let(:fixture_model) { File.join(Rails.root, "app/models/article.rb") }

  before do
    File.write(fixture_model, <<~RUBY)
      class Article < ApplicationRecord
        has_rich_text :content
        has_rich_text :summary
      end
    RUBY
  end

  after { FileUtils.rm_f(fixture_model) }

  it "detects rich text fields via AST" do
    fields = result[:rich_text_fields].select { |f| f[:model] == "Article" }
    expect(fields.size).to eq(2)
    expect(fields.map { |f| f[:field] }).to contain_exactly("content", "summary")
  end
end
```

- [ ] **Step 3: Run test - should pass with current regex (baseline)**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/action_text_introspector_spec.rb`
Expected: PASS

- [ ] **Step 4: Replace `extract_rich_text_fields` with AST**

```ruby
def extract_rich_text_fields
  models_dir = File.join(root, "app/models")
  return [] unless Dir.exist?(models_dir)

  fields = []
  Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
    model_name = File.basename(path, ".rb").camelize
    ast_data = SourceIntrospector.walk(path, { macros: Listeners::MacrosListener })
    ast_data[:macros].each do |m|
      next unless m[:macro] == :has_rich_text
      fields << { model: model_name, field: m[:attribute] }
    end
  end

  fields.sort_by { |f| [f[:model], f[:field]] }
rescue => e
  $stderr.puts "[rails-ai-context] extract_rich_text_fields failed: #{e.message}" if ENV["DEBUG"]
  []
end
```

- [ ] **Step 5: Run all tests**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/action_text_introspector_spec.rb`
Expected: ALL PASS

Run: `bundle exec rspec spec/lib/`
Expected: 2116+ examples, 0 failures

- [ ] **Step 6: Commit**

```bash
git add lib/rails_ai_context/introspectors/action_text_introspector.rb spec/lib/rails_ai_context/introspectors/action_text_introspector_spec.rb
git commit -m "refactor: convert ActionTextIntrospector from regex to Prism AST"
```

---

### Task 5: Create MailboxRoutingListener + Convert ActionMailboxIntrospector

ActionMailbox uses `routing /pattern/ => :action` and lifecycle callbacks (`before_processing`, `after_processing`, `around_processing`). Need a new listener.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/mailbox_routing_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/mailbox_routing_listener_spec.rb`
- Modify: `lib/rails_ai_context/introspectors/action_mailbox_introspector.rb`

- [ ] **Step 1: Write failing test for MailboxRoutingListener**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::MailboxRoutingListener do
  def parse_and_dispatch(source)
    result = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects routing declarations" do
    results = parse_and_dispatch(<<~RUBY)
      class ForwardsMailbox < ApplicationMailbox
        routing /forwards/i => :forward
        routing "support@example.com" => :support
      end
    RUBY

    routing = results.select { |r| r[:type] == :routing }
    expect(routing.size).to eq(2)
  end

  it "detects lifecycle callbacks" do
    results = parse_and_dispatch(<<~RUBY)
      class InboxMailbox < ApplicationMailbox
        before_processing :validate_sender
        after_processing :log_receipt
        around_processing :with_tracking
      end
    RUBY

    callbacks = results.select { |r| r[:type] == :callback }
    expect(callbacks.size).to eq(3)
    expect(callbacks.map { |c| c[:callback_type] }).to contain_exactly(
      "before_processing", "after_processing", "around_processing"
    )
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/listeners/mailbox_routing_listener_spec.rb`
Expected: FAIL - class does not exist

- [ ] **Step 3: Implement MailboxRoutingListener**

```ruby
# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class MailboxRoutingListener < BaseListener
        LIFECYCLE_CALLBACKS = %i[
          before_processing after_processing around_processing
        ].to_set.freeze

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          if node.name == :routing
            extract_routing(node)
          elsif LIFECYCLE_CALLBACKS.include?(node.name)
            extract_callback(node)
          end
        end

        private

        def extract_routing(node)
          args = node.arguments&.arguments || []
          args.each do |arg|
            case arg
            when Prism::KeywordHashNode, Prism::HashNode
              arg.elements.each do |assoc|
                next unless assoc.is_a?(Prism::AssocNode)
                pattern = node_source(assoc.key)
                action = extract_value(assoc.value)
                @results << {
                  type:     :routing,
                  pattern:  pattern,
                  action:   action.to_s,
                  location: node.location.start_line
                }
              end
            end
          end
        end

        def extract_callback(node)
          methods = extract_symbol_args(node)
          methods.each do |method|
            @results << {
              type:          :callback,
              callback_type: node.name.to_s,
              method:        method.to_s,
              location:      node.location.start_line
            }
          end
        end

        def node_source(node)
          node.slice
        rescue
          RailsAiContext::Confidence::INFERRED
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run listener tests**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/listeners/mailbox_routing_listener_spec.rb`
Expected: ALL PASS

- [ ] **Step 5: Replace regex in ActionMailboxIntrospector**

Replace `extract_mailboxes`:

```ruby
def extract_mailboxes
  dir = File.join(root, "app/mailboxes")
  return [] unless Dir.exist?(dir)

  Dir.glob(File.join(dir, "**/*.rb")).filter_map do |path|
    relative = path.sub("#{dir}/", "")
    next if relative == "application_mailbox.rb"

    name = File.basename(path, ".rb").camelize
    ast_data = SourceIntrospector.walk(path, { mailbox: Listeners::MailboxRoutingListener })

    routing = ast_data[:mailbox].select { |r| r[:type] == :routing }.map do |r|
      { pattern: r[:pattern], action: r[:action] }
    end

    callbacks = ast_data[:mailbox].select { |r| r[:type] == :callback }.map do |r|
      { type: r[:callback_type], method: r[:method] }
    end

    entry = { name: name, file: relative, routing: routing }
    entry[:callbacks] = callbacks if callbacks.any?
    entry
  rescue => e
    $stderr.puts "[rails-ai-context] extract_mailboxes failed: #{e.message}" if ENV["DEBUG"]
    nil
  end.compact.sort_by { |m| m[:name] }
end
```

- [ ] **Step 6: Run all tests**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/action_mailbox_introspector_spec.rb`
Expected: ALL PASS

Run: `bundle exec rspec spec/lib/`
Expected: All pass

- [ ] **Step 7: Commit**

```bash
git add lib/rails_ai_context/introspectors/listeners/mailbox_routing_listener.rb spec/lib/rails_ai_context/introspectors/listeners/mailbox_routing_listener_spec.rb lib/rails_ai_context/introspectors/action_mailbox_introspector.rb
git commit -m "refactor: convert ActionMailboxIntrospector from regex to Prism AST"
```

---

### Task 6: Create MiddlewarePatternListener + Convert MiddlewareIntrospector

MiddlewareIntrospector has two regex zones:
1. **Middleware files** (`app/middleware/*.rb`): detects `def call`, `def initialize(app)`, and keyword patterns
2. **Initializer files**: detects `config.middleware.use/insert_before/insert_after`

Zone 1 uses MethodsListener (already exists) for `def call`/`def initialize`. Keyword pattern detection (auth, rate_limit, logging, etc.) stays as regex because it matches against string content, not code structure.

Zone 2 needs a new listener for `config.middleware.*` calls.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/middleware_config_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/middleware_config_listener_spec.rb`
- Modify: `lib/rails_ai_context/introspectors/middleware_introspector.rb`

- [ ] **Step 1: Write failing test for MiddlewareConfigListener**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe RailsAiContext::Introspectors::Listeners::MiddlewareConfigListener do
  def parse_and_dispatch(source)
    result = Prism.parse(source)
    dispatcher = Prism::Dispatcher.new
    listener = described_class.new
    dispatcher.register(listener, :on_call_node_enter)
    dispatcher.dispatch(result.value)
    listener.results
  end

  it "detects config.middleware.use" do
    results = parse_and_dispatch(<<~RUBY)
      Rails.application.configure do
        config.middleware.use Rack::Deflater
        config.middleware.use ActionDispatch::SSL
      end
    RUBY

    expect(results.size).to eq(2)
    expect(results.first[:middleware]).to eq("Rack::Deflater")
    expect(results.first[:action]).to eq("use")
  end

  it "detects insert_before and insert_after" do
    results = parse_and_dispatch(<<~RUBY)
      config.middleware.insert_before ActionDispatch::Static, MyMiddleware
      config.middleware.insert_after Rack::Sendfile, AnotherMiddleware
    RUBY

    expect(results.size).to eq(2)
    actions = results.map { |r| r[:action] }
    expect(actions).to contain_exactly("insert_before", "insert_after")
  end

  it "detects unshift" do
    results = parse_and_dispatch("config.middleware.unshift CorsMiddleware")
    expect(results.size).to eq(1)
    expect(results.first[:action]).to eq("unshift")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/listeners/middleware_config_listener_spec.rb`
Expected: FAIL - class does not exist

- [ ] **Step 3: Implement MiddlewareConfigListener**

```ruby
# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class MiddlewareConfigListener < BaseListener
        MIDDLEWARE_ACTIONS = %i[use insert_before insert_after insert unshift].to_set.freeze

        def on_call_node_enter(node)
          return unless MIDDLEWARE_ACTIONS.include?(node.name)
          return unless middleware_config_receiver?(node)

          args = node.arguments&.arguments || []
          middleware_name = resolve_constant(args, node.name)
          return unless middleware_name

          @results << {
            action:     node.name.to_s,
            middleware: middleware_name,
            location:   node.location.start_line
          }
        end

        private

        def middleware_config_receiver?(node)
          receiver = node.receiver
          return false unless receiver.is_a?(Prism::CallNode) && receiver.name == :middleware

          inner = receiver.receiver
          return false unless inner.is_a?(Prism::CallNode) && inner.name == :config
          true
        end

        def resolve_constant(args, action)
          idx = %i[insert_before insert_after].include?(action) ? 1 : 0
          arg = args[idx]
          case arg
          when Prism::ConstantReadNode then arg.name.to_s
          when Prism::ConstantPathNode then constant_path_string(arg)
          else nil
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run listener tests**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/listeners/middleware_config_listener_spec.rb`
Expected: ALL PASS

- [ ] **Step 5: Replace `discover_custom_middleware` with AST for `has_call_method` and `initializes_app`**

In `middleware_introspector.rb`, update `discover_custom_middleware`:

```ruby
def discover_custom_middleware
  middleware_dir = File.join(root, "app/middleware")
  return [] unless Dir.exist?(middleware_dir)

  Dir.glob(File.join(middleware_dir, "**/*.rb")).sort.map do |path|
    content = RailsAiContext::SafeFile.read(path) or next
    class_name = File.basename(path, ".rb").camelize

    ast_data = SourceIntrospector.walk(path, { methods: Listeners::MethodsListener })
    method_names = ast_data[:methods].map { |m| m[:name] }

    info = {
      file: path.sub("#{root}/", ""),
      class_name: class_name,
      has_call_method: method_names.include?("call"),
      initializes_app: ast_data[:methods].any? { |m|
        m[:name] == "initialize" && m[:params]&.any? { |p| p[:name] == "app" }
      }
    }

    patterns = []
    patterns << "authentication" if content.match?(/auth|token|session|jwt/i)
    patterns << "rate_limiting" if content.match?(/rate.?limit|throttl/i)
    patterns << "logging" if content.match?(/log|Logger/i)
    patterns << "cors" if content.match?(/cors|origin|Access-Control/i)
    patterns << "caching" if content.match?(/cache|Cache-Control|etag/i)
    patterns << "error_handling" if content.match?(/rescue|error|exception/i)
    patterns << "tenant" if content.match?(/tenant|subdomain|account/i)
    info[:detected_patterns] = patterns if patterns.any?

    info
  rescue => e
    { file: path.sub("#{root}/", ""), error: e.message }
  end
end
```

Note: `detected_patterns` stays as regex - it matches against semantic keywords in content, not code structure. AST would not improve this.

- [ ] **Step 6: Replace `detect_middleware_from_initializers` with AST**

```ruby
def detect_middleware_from_initializers
  init_dir = File.join(root, "config/initializers")
  return [] unless Dir.exist?(init_dir)

  additions = []
  Dir.glob(File.join(init_dir, "*.rb")).each do |path|
    ast_data = SourceIntrospector.walk(path, { middleware: Listeners::MiddlewareConfigListener })
    ast_data[:middleware].each do |m|
      additions << { middleware: m[:middleware], file: File.basename(path) }
    end
  end
  additions.uniq
rescue => e
  $stderr.puts "[rails-ai-context] detect_middleware_from_initializers failed: #{e.message}" if ENV["DEBUG"]
  []
end
```

- [ ] **Step 7: Run all tests**

Run: `bundle exec rspec spec/lib/rails_ai_context/introspectors/middleware_introspector_spec.rb`
Expected: ALL PASS

Run: `bundle exec rspec spec/lib/`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add lib/rails_ai_context/introspectors/listeners/middleware_config_listener.rb spec/lib/rails_ai_context/introspectors/listeners/middleware_config_listener_spec.rb lib/rails_ai_context/introspectors/middleware_introspector.rb
git commit -m "refactor: convert MiddlewareIntrospector from regex to Prism AST"
```

---

## Phase 2: Controller Pattern Listeners

### Task 7: Create FilterListener

Detects `before_action`, `after_action`, `around_action`, `skip_before_action`, `prepend_before_action`, `append_before_action` with `only:`, `except:`, `if:`, `unless:` options.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/filter_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/filter_listener_spec.rb`

**Pattern:** Similar to CallbacksListener but for controller filters. Registers `on_call_node_enter`. Extracts filter name (symbol arg), type (method name), and constraint options (only, except, if, unless).

**Result shape:**
```ruby
{ type: "before_action", method: "authenticate!", options: { only: [:create, :update] }, location: 5 }
```

### Task 8: Create StrongParamsListener

Detects `params.require(:name).permit(:field1, :field2)` chains. This is a complex AST pattern: a method chain where `require` is called on `params` and `permit` is called on the result.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/strong_params_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/strong_params_listener_spec.rb`

**Pattern:** Registers `on_call_node_enter`. Detects `permit` calls whose receiver chain includes `params.require`. Extracts require key, permitted fields (including nested and array params). Also detects `params.permit!` (unrestricted).

**Result shape:**
```ruby
{ require: :post, permit: [:title, :body, { tags: [] }], unrestricted: false, location: 12 }
```

### Task 9: Create ControllerMacroListener

Detects controller-level DSL calls: `protect_from_forgery`, `skip_forgery_protection`, `allow_browser`, `allow_unauthenticated_access`, `rescue_from`, `rate_limit`, `layout`.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/controller_macro_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/controller_macro_listener_spec.rb`

**Pattern:** Similar to MacrosListener. Registers `on_call_node_enter` for known controller macro names. Extracts name + options.

**Result shape:**
```ruby
{ macro: :protect_from_forgery, options: { with: :exception }, location: 3 }
{ macro: :rescue_from, exception: "ActiveRecord::RecordNotFound", handler: "not_found", location: 5 }
{ macro: :rate_limit, args: "to: 10, within: 1.minute", location: 7 }
```

### Task 10: Convert ControllerIntrospector

Replace regex for: parent class extraction, action definitions, filters, strong params, respond_to formats, rescue_from, rate_limit, Turbo stream detection. Keep runtime reflection (`action_methods`, `_process_action_callbacks`) as-is.

**Files:**
- Modify: `lib/rails_ai_context/introspectors/controller_introspector.rb`
- Modify: `spec/lib/rails_ai_context/introspectors/controller_introspector_spec.rb`

Uses: MethodsListener (actions), FilterListener (filters), StrongParamsListener (params), ControllerMacroListener (protect_from_forgery, rescue_from, rate_limit), ModelReferenceListener (model detection)

### Task 11: Convert SecurityIntrospector (controller scanning)

Replace regex in `extract_csrf` and `extract_allow_browser` with ControllerMacroListener AST walks. Keep runtime config queries as-is.

**Files:**
- Modify: `lib/rails_ai_context/introspectors/security_introspector.rb`

### Task 12: Convert AuthIntrospector (controller scanning)

Replace regex in `scan_allow_unauthenticated_access` and `detect_http_token_auth` with ControllerMacroListener + ChainedCallListener AST walks.

**Files:**
- Modify: `lib/rails_ai_context/introspectors/auth_introspector.rb`

---

## Phase 3: Initializer/Config Pattern Listeners

### Task 13: Create ConfigAssignmentListener

Detects `config.key = value` and `config.key.subkey = value` patterns in initializer files.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/config_assignment_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/config_assignment_listener_spec.rb`

**Pattern:** Registers `on_call_node_enter`. Detects calls where the receiver chain starts with `config`. Handles both assignment (`config.x = val`) and method calls (`config.x.y val`).

**Result shape:**
```ruby
{ path: "config.timeout_in", value: "30.minutes", location: 5 }
{ path: "config.lock_strategy", value: :email, location: 6 }
```

### Task 14: Create PolicyDirectiveListener

Detects `policy.directive :arg1, :arg2` in CSP and PermissionsPolicy initializers.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/policy_directive_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/policy_directive_listener_spec.rb`

**Result shape:**
```ruby
{ directive: "default_src", value: ":self", location: 3 }
```

### Task 15: Convert SecurityIntrospector (initializer scanning)

Replace `extract_csp` and `extract_permissions_policy` regex with PolicyDirectiveListener.

### Task 16: Convert MiddlewareIntrospector (already done in Phase 1 Task 6)

Verify no remaining regex patterns.

### Task 17: Convert AuthIntrospector (initializer scanning)

Replace `extract_devise_settings`, `detect_omniauth_providers`, `detect_devise_jwt`, `detect_doorkeeper` regex with ConfigAssignmentListener + MacrosListener walks.

### Task 18: Convert AutoloadIntrospector (inflection scanning)

Replace inflection regex (`inflect.acronym`, `inflect.plural`, etc.) with a ConfigAssignmentListener walk. Keep runtime reflection (`Rails.autoloaders`) as-is.

**Files:**
- Modify: `lib/rails_ai_context/introspectors/autoload_introspector.rb`

---

## Phase 4: Model Pattern Extensions

### Task 19: Create DeviseListener

Detects `devise :confirmable, :registerable, ...` (multi-symbol args). Separate from MacrosListener because devise takes a variable number of module symbols, not a single attribute.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/devise_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/devise_listener_spec.rb`

**Result shape:**
```ruby
{ modules: [:confirmable, :registerable, :trackable], options: {}, location: 3 }
```

### Task 20: Create MultiDbListener

Detects `connects_to` and `connected_to` calls in model files.

**Files:**
- Create: `lib/rails_ai_context/introspectors/listeners/multi_db_listener.rb`
- Create: `spec/lib/rails_ai_context/introspectors/listeners/multi_db_listener_spec.rb`

**Result shape:**
```ruby
{ type: :connects_to, config: { database: { writing: :primary, reading: :primary_replica } }, location: 3 }
```

### Task 21: Convert AuthIntrospector (model scanning)

Replace `detect_devise_modules_per_model` and `scan_models_for` regex with DeviseListener + MacrosListener walks. Keep `gem_present?` (Gemfile.lock) as-is.

### Task 22: Convert MultiDatabaseIntrospector

Replace `connects_to`/`connected_to` regex with MultiDbListener. Keep YAML parsing and runtime config as-is.

### Task 23: Convert ConventionIntrospector

Replace pattern-detection regex (`acts_as_paranoid`, `has_paper_trail`, `aasm`, `encrypts`, `normalizes`, etc.) with MacrosListener + ConventionMacroListener walks. Many patterns are simple macro calls already covered by MacrosListener. Create ConventionMacroListener only for patterns not already covered.

---

## Phase 5: DSL File Patterns

### Task 24: Create MigrationDslListener

Detects `create_table`, `add_column`, `add_index`, `remove_column`, `rename_column`, `add_foreign_key`, `add_reference` in migration files.

**Result shape:**
```ruby
{ action: :create_table, table: "users", columns: [...], location: 3 }
{ action: :add_index, table: "users", columns: ["email"], options: { unique: true }, location: 15 }
```

### Task 25: Create SchemaDslListener

Detects schema.rb-specific patterns: `create_table` with `t.type "column"` block content, `t.index`, `add_foreign_key`, `create_enum`.

### Task 26: Create GemfileDslListener

Detects `gem "name", options` and `group :name do` blocks in Gemfile. Cannot parse Gemfile.lock (not Ruby) - that stays as-is.

### Task 27: Create RakeTaskDslListener

Detects `namespace :name do`, `desc "text"`, `task :name => [:dep1, :dep2]` in .rake files.

### Task 28: Create MountListener

Detects `mount Engine, at: "/path"` and `mount Engine => "/path"` in routes.rb.

### Task 29: Create ImportmapListener

Detects `pin "name"`, `pin_all_from "dir"` in config/importmap.rb.

### Task 30: Convert Introspectors

Convert: MigrationIntrospector, SchemaIntrospector, GemIntrospector (Gemfile only), RakeTaskIntrospector, EngineIntrospector (mount detection), AssetPipelineIntrospector (importmap only).

---

## Phase 6: Miscellaneous File Patterns

### Task 31: Create EnvAccessListener

Detects `ENV["KEY"]`, `ENV.fetch("KEY")`, `ENV.fetch("KEY", default)` patterns.

### Task 32: Create SeedPatternListener

Detects `Model.create`, `Model.find_or_create_by`, `Model.upsert`, etc. in seed files.

### Task 33: Create PumaConfigListener

Detects `threads min, max`, `workers n`, `port n` in config/puma.rb.

### Tasks 34-38: Convert Introspectors

Convert: EnvIntrospector, SeedsIntrospector, DevOpsIntrospector (puma.rb), ApiIntrospector (Ruby parts), PerformanceIntrospector (schema + model scanning), TestIntrospector (Ruby file scanning).

---

## Phase 7: View/Component Patterns

### Task 39: Create ComponentStructureListener

Detects `renders_one :name`, `renders_many :name`, class hierarchy (`< ViewComponent::Base`), `initialize` params. The most complex new listener - handles class-level and method-level patterns.

### Task 40: Create PartialRenderListener

Detects `render partial: "name"`, `render @collection`, `render Component.new` patterns in Ruby files. Note: only works for `.rb` files (helpers, components), not ERB templates.

### Task 41: Create TurboViewListener

Detects `turbo_frame_tag`, `turbo_stream.*` in Ruby helpers. Note: most Turbo patterns are in ERB templates where Prism cannot fully parse.

### Tasks 42-45: Convert Introspectors

Convert: ComponentIntrospector, ViewIntrospector (helper scanning, layout declarations), ViewTemplateIntrospector (Ruby-file portions only), TurboIntrospector (model broadcast + controller turbo_stream), StimulusIntrospector (Ruby-file portions only), FrontendFrameworkIntrospector (Ruby-file portions only).

---

## Phase 8: Cleanup + Integration

### Task 46: Convert ActiveSupportIntrospector

Replace `included do`, `class_methods do` regex with MacrosListener or a new ConcernStructureListener. Keep runtime reflection (`app.deprecators`, `app.config.*`) as-is.

### Task 47: Convert ConfigIntrospector

Replace Sidekiq YAML regex with YAML parsing (already non-Ruby). Replace remaining `config.` regex patterns with ConfigAssignmentListener. Keep runtime reflection as-is.

### Task 48: Audit all introspectors for remaining regex

Grep every introspector for `.scan(`, `.match(`, `.match?(` on Ruby source content. Any remaining regex on `.rb` file content should be converted or explicitly documented as intentionally regex (e.g., keyword pattern detection where AST adds no value).

### Task 49: Integration test

Run full test suite (`bundle exec rspec spec/lib/`) and verify 0 failures. Run E2E tests (`E2E=1 bundle exec rspec spec/e2e/`) to verify end-to-end behavior is unchanged.

### Task 50: Update INTROSPECTORS.md

Document the AST architecture in `docs/INTROSPECTORS.md`: which listeners exist, how to add new ones, which patterns are intentionally regex vs AST.

---

## Execution Notes

- **Each phase is independently shippable.** Phase 1 produces working software. Each subsequent phase adds more conversions.
- **Output format is sacred.** The existing test suite validates output format. AST conversion must not change any return values.
- **Regex is OK for non-code patterns.** Keyword detection (`/auth|token|session/i`), file content classification, and non-Ruby file parsing intentionally stay as regex. The goal is AST for *code structure extraction*, not AST for everything.
- **SourceIntrospector.call(path) is unchanged.** The existing `call` method still works with the default LISTENER_MAP. The new `walk` method is additive.
- **Listener naming convention:** `{Domain}Listener` for domain-specific listeners (e.g., `DeviseListener`), `{Pattern}Listener` for generic patterns (e.g., `ChainedCallListener`).
