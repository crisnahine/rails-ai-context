# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::UnbootedSettings do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def write(relative, source)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def read
    described_class.read(@root)
  end

  def configure(body)
    "RailsAiContext.configure do |config|\n#{body}\nend\n"
  end

  it "reads the YAML alone, the way the boot loads it" do
    write(".rails-ai-context.yml", "ai_tools: [cursor]\ntool_mode: cli\ncontext_files: false\nskip_tools: [rails_query]\n")
    settings = read

    expect(settings.ai_tools).to eq(%i[cursor])
    expect(settings.tool_mode).to eq(:cli)
    expect(settings.context_files).to be(false)
    expect(settings.config.skip_tools).to eq(%w[rails_query])
    expect(settings.served_tool_names).not_to include("rails_query")
    expect(settings.served_tool_names).to include("rails_get_schema")
    expect(settings.refusals).to be_empty
  end

  it "lets an initializer's literal win over the YAML for a key that is not a list of patterns" do
    write(".rails-ai-context.yml", "ai_tools: [cursor]\ntool_mode: cli\n")
    write("config/initializers/rails_ai_context.rb", configure("  config.ai_tools = %i[claude]\n  config.context_files = false"))
    settings = read

    expect(settings.ai_tools).to eq(%i[claude])
    expect(settings.config.ai_tools).to eq(%i[claude])
    expect(settings.context_files).to be(false)
    expect(settings.tool_mode).to eq(:cli)
  end

  it "reads an explicit empty list as no tool, as the boot keeps it, and nil only where nothing sets one" do
    write(".rails-ai-context.yml", "ai_tools: [cursor]\n")
    write("config/initializers/rails_ai_context.rb", configure("  config.ai_tools = %i[]"))
    expect([ read.ai_tools, read.config.ai_tools ]).to eq([ [], [] ])

    write(".rails-ai-context.yml", "tool_mode: cli\n")
    write("config/initializers/rails_ai_context.rb", configure("  config.tool_mode = :cli"))
    expect([ read.ai_tools, read.config.ai_tools ]).to eq([ nil, nil ])
  end

  # One table for both readers: the same writes reach the configuration. A write that may not run is
  # left unread for a selection key and added for a security list, the stricter reading of each.
  describe "which writes reach the configuration" do
    shapes = {
      "the configure block's param" => [ "RailsAiContext.configure do |config|\n  config.KEY = VALUE\nend\n", :read ],
      "a param of another name" => [ "RailsAiContext.configure { |c| c.KEY = VALUE }\n", :read ],
      "the configuration called by name" => [ "RailsAiContext.configuration.KEY = VALUE\n", :read ],
      "the generated initializer's guard" => [ "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)\n" \
                                               "  RailsAiContext.configure do |config|\n    config.KEY = VALUE\n  end\nend\n", :read ],
      "the guard written as a modifier" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if defined?(RailsAiContext)\n", :read ],
      "a modifier `if` on the environment" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if Rails.env.test?\n", :conditional ],
      "the guard spelled ::RailsAiContext" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if defined?(::RailsAiContext)\n", :read ],
      "the guard spelled Object::RailsAiContext" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if defined?(Object::RailsAiContext)\n", :read ],
      "a respond_to? guard on the module" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if ::RailsAiContext.respond_to?(:configure)\n", :read ],
      "the guard inside the block" => [ "RailsAiContext.configure do |config|\n  config.KEY = VALUE if defined?(RailsAiContext)\nend\n", :read ],
      "another constant in `defined?`" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if defined?(Rails::Console)\n", :conditional ],
      "a constant of the gem in `defined?`" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if defined?(RailsAiContext::Engine)\n", :conditional ],
      "a `defined?` of another constant inside the block" => [ "RailsAiContext.configure do |config|\n  config.KEY = VALUE if defined?(Rails::Console)\nend\n", :conditional ],
      "a `respond_to?` on another object" => [ "if ENV.respond_to?(:fetch)\n  RailsAiContext.configure { |c| c.KEY = VALUE }\nend\n", :conditional ],
      "a guard `and` another constant's" => [ "RailsAiContext.configure { |c| c.KEY = VALUE } if defined?(RailsAiContext) && defined?(Rails::Console)\n", :conditional ],
      "a top-level return on the environment" => [ "return unless ENV[\"A\"]\nRailsAiContext.configure { |c| c.KEY = VALUE }\n", :conditional ],
      "a top-level return `if` a condition" => [ "return if Rails.env.test?\nRailsAiContext.configure { |c| c.KEY = VALUE }\n", :conditional ],
      "a top-level return `unless` the guard" => [ "return unless defined?(RailsAiContext)\nRailsAiContext.configure { |c| c.KEY = VALUE }\n", :read ],
      "a top-level return `if` the guard holds" => [ "return if defined?(RailsAiContext)\nRailsAiContext.configure { |c| c.KEY = VALUE }\n", :conditional ],
      "a top-level return `if` the guard is negated" => [ "return if !defined?(RailsAiContext)\nRailsAiContext.configure { |c| c.KEY = VALUE }\n", :read ],
      "an `and return` on the environment" => [ "ENV[\"A\"] or return\nRailsAiContext.configure { |c| c.KEY = VALUE }\n", :conditional ],
      "a `next` on the environment in the block" => [ "RailsAiContext.configure do |config|\n  next unless ENV[\"A\"]\n  config.KEY = VALUE\nend\n", :conditional ],
      "a return before a write that precedes it" => [ "RailsAiContext.configure { |c| c.KEY = VALUE }\nreturn unless ENV[\"A\"]\n", :read ],
      "an object that is not the configuration" => [ "require \"ostruct\"\nsettings = OpenStruct.new\nsettings.KEY = VALUE\n", :none ],
      "a proc's own param" => [ "apply = proc { |c| c.KEY = VALUE }\n", :none ],
      "an `if` on the environment" => [ "RailsAiContext.configure do |config|\n  if Rails.env.test?\n    config.KEY = VALUE\n  end\nend\n", :conditional ],
      "a `case` branch" => [ "RailsAiContext.configure do |config|\n  case Rails.env\n  when \"test\" then config.KEY = VALUE\n  end\nend\n", :conditional ],
      "a proc in the configure block" => [ "RailsAiContext.configure do |config|\n  later = proc { config.KEY = VALUE }\nend\n", :conditional ],
      "an after_initialize hook" => [ "Rails.application.config.after_initialize { RailsAiContext.configuration.KEY = VALUE }\n", :conditional ],
      "another library's configure block" => [ "Sentry.configure do |config|\n  config.KEY = VALUE\nend\n", :none ],
      "another library's block whose param hides the gem's" => [ "RailsAiContext.configure do |config|\n  Other.configure do |config|\n" \
                                                                  "    config.KEY = VALUE\n  end\nend\n", :none ],
      "another library's configure block inside the gem's" => [ "RailsAiContext.configure do |config|\n  Other.configure { |c| config.KEY = VALUE }\nend\n",
                                                                 :conditional ],
      "a block's keyword param that hides the gem's" => [ "RailsAiContext.configure do |config|\n  [1].each { |config: nil| config.KEY = VALUE }\nend\n",
                                                          :none ],
      "the app's own configure block" => [ "Rails.application.configure do\n  RailsAiContext.configuration.KEY = VALUE\nend\n", :read ],
      "the app config's rails_ai_context, set only after the initializers" => [ "Rails.application.configure do\n  config.rails_ai_context.KEY = VALUE\nend\n",
                                                                               :conditional ]
    }

    shapes.each do |shape, (source, reach)|
      it "reads #{shape} as #{reach} for the selection and the security lists" do
        write(".rails-ai-context.yml", "ai_tools: [cursor]\n")
        write("config/initializers/a.rb", source.gsub("KEY", "ai_tools").gsub("VALUE", "%i[codex]"))
        settings = read
        expect(settings.ai_tools).to eq(reach == :read ? %i[codex] : %i[cursor])
        expect(settings.refusals.map(&:key)).to eq(reach == :conditional ? %i[ai_tools] : [])

        write("config/initializers/a.rb", source.gsub("KEY", "skip_tools").gsub("VALUE", "%w[rails_get_gems]"))
        settings = read
        expect(settings.config.skip_tools.include?("rails_get_gems")).to eq(reach != :none)
        expect(settings.static_refusal).to be_nil
      end
    end
  end

  it "reads a block param's default as a read of the configuration, in both readers" do
    write(".rails-ai-context.yml", "ai_tools: [cursor]\n")
    write("config/initializers/a.rb", configure("  [1].each { |x = config| config.ai_tools = %i[codex]; config.skip_tools << \"rails_get_env\" }"))
    settings = read

    expect(settings.ai_tools).to eq(%i[cursor])
    expect(settings.refusals.map { |refusal| [ refusal.line, refusal.key, refusal.stops_static ] }.uniq)
      .to contain_exactly([ 2, :ai_tools, false ], [ 2, nil, false ], [ 2, nil, true ])
    expect([ settings.static_refusal.line, settings.static_refusal.key ]).to eq([ 2, nil ])
  end

  it "keeps the last literal the boot order writes: application.rb, then the environment, then the initializers in order" do
    write("config/application.rb", configure("  config.tool_mode = :cli"))
    write("config/environments/development.rb", configure("  config.anti_hallucination_rules = false"))
    write("config/environments/production.rb", configure("  config.anti_hallucination_rules = true"))
    write("config/initializers/a.rb", configure("  config.ai_tools = %i[cursor]"))
    write("config/initializers/b.rb", configure("  config.ai_tools = [:codex, \"claude\"].freeze"))
    write(".rails-ai-context.yml", "tool_mode: mcp\n")
    settings = read

    expect(settings.tool_mode).to eq(:cli)
    expect(settings.ai_tools).to eq(%i[codex claude])
    expect(settings.config.anti_hallucination_rules).to be(false)
  end

  # A failed boot leaves the static tier this reader's configuration, so each key a literal sets must reach it.
  describe "a literal for every key the YAML takes" do
    literals = {
      ai_tools: "%i[codex]", tool_mode: ":cli", context_mode: ":full", context_files: "false", generate_root_files: "false",
      claude_max_lines: "99", anti_hallucination_rules: "false", report_issue_line: "false", server_name: '"probe"', cache_ttl: "7",
      max_tool_response_chars: "12_345", live_reload: "false", live_reload_debounce: "2.5", auto_mount: "true",
      http_path: '"/probe"', http_bind: '"0.0.0.0"', http_port: "7123", allow_http_in_production: "true",
      output_dir: '"tmp/probe"', excluded_models: "%w[Secret]", excluded_controllers: "%w[AdminController]",
      excluded_route_prefixes: "%w[admin/]", excluded_filters: "%w[audit]", excluded_middleware: "%w[Rack::Probe]",
      excluded_association_names: "%w[secrets]", excluded_concerns: "%w[Probeable]", search_extensions: "%w[rb erb]",
      concern_paths: "%w[app/probe]", frontend_paths: "%w[web]", extra_app_paths: "%w[lib/probe]",
      max_file_size: "1_000", max_test_file_size: "2_000", max_schema_file_size: "3_000", max_view_total_size: "4_000",
      max_view_file_size: "5_000", max_search_results: "6", max_validate_files: "8", query_timeout: "9",
      query_row_limit: "50", query_redacted_columns: "%w[ssn]", query_allowed_columns: "%w[email]",
      allow_query_in_production: "true", log_lines: "20", introspectors: "%i[schema models]", hydration_enabled: "false",
      hydration_max_hints: "3", instrumentation_include_arguments: "true"
    }
    files = %w[config/application.rb config/environments/development.rb config/initializers/rails_ai_context.rb]

    it "names every key" do
      expect(literals.keys).to match_array(described_class::KEYS - %i[preset])
    end

    it "gives the static tier each value as the boot's setter takes it, whichever file writes it" do
      literals.each_slice((literals.size / files.size) + 1).zip(files) do |slice, file|
        write(file, configure(slice.map { |key, value| "  config.#{key} = #{value}" }.join("\n")))
      end
      config = read.config

      literals.each do |key, value|
        expected = RailsAiContext::Configuration.new.tap { |fresh| fresh.public_send(:"#{key}=", eval(value)) }.public_send(key) # rubocop:disable Security/Eval
        expect(config.public_send(key)).to eq(expected), key.to_s
      end
      expect(read.refusals).to be_empty
    end

    it "takes a preset, in the order the writes run" do
      write("config/application.rb", configure("  config.preset = :full\n  config.introspectors = %i[schema]\n  config.preset = :standard"))

      expect(read.config.introspectors).to eq(RailsAiContext::Configuration::PRESETS[:standard])
    end
  end

  it "adds a pattern application.rb appends to the YAML's list instead of losing it" do
    write("config/application.rb", "RailsAiContext.configure { |c| c.sensitive_patterns << \"config/partner_keys.yml\" }\n")
    write(".rails-ai-context.yml", "sensitive_patterns: [config/master.key]\n")
    settings = read

    expect(settings.config.sensitive_patterns).to include("config/partner_keys.yml", "config/master.key")
    expect(settings.refusals).to be_empty
  end

  it "reads a list built from literals alone without refusing it" do
    write("config/initializers/rails_ai_context.rb",
          configure("  config.skip_tools = %w[rails_get_gems] + %w[rails_get_conventions]\n" \
                    "  config.excluded_paths = (%w[a b] | %w[c]).freeze"))
    settings = read

    expect(settings.static_refusal).to be_nil
    expect(settings.config.skip_tools).to include("rails_get_gems", "rails_get_conventions")
    expect(settings.config.excluded_paths).to include("a", "b", "c")
  end

  it "serves a tree whose file reads a frozen constant of the configuration at its top level" do
    write("app/models/user.rb", "class User < ApplicationRecord; end\n")
    write("lib/preset_count.rb", "PRESET_COUNT = RailsAiContext::Configuration::PRESETS[:full].size\n")
    write("config/initializers/presets.rb", "PRESETS = RailsAiContext::Configuration::PRESETS.keys\n")

    expect(read.refusals).to be_empty
  end

  it "still refuses a top-level line that reaches the configuration's class itself" do
    write("app/models/user.rb", "class User < ApplicationRecord; end\n")
    write("lib/patch.rb", "RailsAiContext::Configuration::BLOCK_ASSIGNMENT_RECORDER.send(:remove_method, :skip_tools=)\n")

    refusal = read.static_refusal
    expect(refusal).to have_attributes(file: "lib/patch.rb", line: 1)
    expect(refusal.message).to include("lib/patch.rb:1:", "the static tier cannot read")
  end

  it "reads only the YAML of a folder that holds no app" do
    write(".rails-ai-context.yml", "skip_tools: [rails_query]\n")
    write("notes/setup.rb", "RailsAiContext.configure { |c| c.skip_tools = ENV.fetch(\"SKIP\").split }\n")
    settings = read

    expect(settings.refusals).to be_empty
    expect(settings.config.skip_tools).to eq(%w[rails_query])
  end

  it "names the file and line of a security setting it cannot read, and still answers the rest" do
    write(".rails-ai-context.yml", "ai_tools: [claude]\n")
    write("config/initializers/rails_ai_context.rb", configure("  config.skip_tools = ENV.fetch(\"SKIP\").split(\",\")"))
    settings = read

    expect(settings.static_refusal).to have_attributes(file: "config/initializers/rails_ai_context.rb", line: 2, key: :skip_tools)
    expect(settings.ai_tools).to eq(%i[claude])
  end

  it "reports a value computed at boot for a selection key without stopping the static tier" do
    write(".rails-ai-context.yml", "tool_mode: cli\n")
    write("config/initializers/rails_ai_context.rb", configure("  config.tool_mode = ENV[\"MODE\"] ? :mcp : :cli\n  config.ai_tools ||= %i[claude]"))
    settings = read

    expect(settings.tool_mode).to eq(:cli)
    expect(settings.ai_tools).to be_nil
    expect(settings.refusals).to contain_exactly(have_attributes(file: "config/initializers/rails_ai_context.rb", line: 2, key: :tool_mode),
                                                 have_attributes(line: 3, key: :ai_tools))
    expect(settings.static_refusal).to be_nil
  end

  describe "an in-place edit of a selection key" do
    before { write(".rails-ai-context.yml", "ai_tools: [cursor]\nexcluded_models: [FromYaml]\n") }

    def answer(body, file: "config/initializers/rails_ai_context.rb")
      write(file, configure(body))
      settings = read
      [ settings.ai_tools, settings.refusals.reject(&:stops_static?).map { |refusal| [ refusal.line, refusal.key ] } ]
    end

    followed = {
      "config.ai_tools << :copilot" => %i[codex copilot],
      "config.ai_tools << :copilot << :cursor" => %i[codex copilot cursor],
      "config.ai_tools.<<(:copilot)" => %i[codex copilot],
      "config.ai_tools.push(:copilot, :cursor)" => %i[codex copilot cursor],
      "config.ai_tools.append :copilot" => %i[codex copilot],
      "config.ai_tools.concat %i[copilot]" => %i[codex copilot],
      "config.ai_tools.unshift(:copilot)" => %i[copilot codex],
      "config.ai_tools.delete(:codex)" => [],
      "config.ai_tools.clear" => [],
      "config.ai_tools&.push(:copilot)" => %i[codex copilot],
      "config.ai_tools.include?(:codex)" => %i[codex],
      "puts config.ai_tools.inspect" => %i[codex],
      "config.ai_tools.dup << :copilot" => %i[codex],
      "config.ai_tools, other = %i[copilot], 1" => %i[copilot],
      "other, config.ai_tools = 1, %i[copilot]" => %i[copilot],
      "config.ai_tools, config.tool_mode = %i[copilot], :cli" => %i[copilot]
    }
    followed.each do |edit, expected|
      it "follows #{edit} in order, as the boot runs it" do
        expect(answer("  config.ai_tools = %i[codex]\n  #{edit}")).to eq([ expected, [] ])
      end
    end

    it "deletes an element only where Ruby's == holds: a Symbol never equals a String" do
      expect(answer("  config.ai_tools = %i[codex]\n  config.ai_tools.delete(\"codex\")")).to eq([ %i[codex], [] ])
      expect(answer("  config.ai_tools = [:codex, \"claude\"]\n  config.ai_tools.delete(:claude)\n  config.ai_tools.delete(\"codex\")")).to eq([ %i[codex claude], [] ])
      expect(answer("  config.ai_tools = %i[codex claude]\n  config.ai_tools.delete(:codex)")).to eq([ %i[claude], [] ])
      write("config/initializers/rails_ai_context.rb", configure("  config.excluded_models = %w[A B]\n  config.excluded_models.delete(:A)\n  config.excluded_models.delete(\"B\")"))
      expect(read.config.excluded_models).to eq(%w[A])
    end

    it "follows an edit of the YAML's own value from an initializer, and leaves one before the YAML loads to the YAML" do
      expect(answer("  config.ai_tools << :copilot")).to eq([ %i[cursor copilot], [] ])
      expect(answer("  config.ai_tools << :copilot", file: "config/application.rb")).to eq([ %i[cursor], [ [ 2, :ai_tools ] ] ])
    end

    unfollowed = [
      "config.ai_tools.replace(%i[copilot])", "config.ai_tools.map!(&:to_sym)", "config.ai_tools[0] = :copilot",
      "config.ai_tools.concat(extra)", "config.ai_tools.push(extra)", "config.send(:ai_tools=, %i[copilot])",
      "config.public_send :ai_tools=, %i[copilot]", "config.instance_variable_set(:@ai_tools, [])",
      "tools = config.ai_tools\n  tools << :copilot", "(tools = config.ai_tools) << :copilot", "[config.ai_tools].first << :copilot",
      "config.ai_tools.tap { |t| t << :copilot }", "config.ai_tools.then { |t| t.push(:copilot) }",
      "config.ai_tools.each { |t| t.to_s }", "config.ai_tools.map(&:to_s)", "log(config.ai_tools)",
      "config.ai_tools.send(:push, :copilot)", "config.ai_tools.public_send(:<<, :copilot)",
      "config.ai_tools.method(:push).call(:copilot)", "config.ai_tools.instance_eval { push(:copilot) }",
      "config.ai_tools, other = list", "config.ai_tools, other = %i[copilot]", "config.ai_tools, other = *list, 1", "*other, config.ai_tools = 1, 2",
      "(config.ai_tools, other), more = [ %i[copilot], 1 ], 1", "config.ai_tools, *other = %i[copilot], 1", "config.ai_tools, other = list, 1",
      "config.ai_tools + %i[copilot]", "->(list) { list << :copilot }.call(config.ai_tools)"
    ]
    unfollowed.each do |edit|
      it "reports #{edit.inspect} and answers from the YAML" do
        value, refusals = answer("  config.ai_tools = %i[codex]\n  def extra = %i[copilot]\n  #{edit}")
        expect(value).to eq(%i[cursor]), edit
        expect(refusals.map(&:last)).to include(:ai_tools), edit
      end
    end

    reflective = [
      "config.tap { |c| c.ai_tools = %i[copilot] }", "config.then { |c| c.ai_tools = %i[copilot] }",
      "config.instance_eval { self.ai_tools = %i[copilot] }", "config.instance_exec { @ai_tools = %i[copilot] }",
      "config.send(\"ai_\#{'tools'}=\", %i[copilot])", "name = :ai_tools=\n  config.send(name, %i[copilot])",
      "config.method(:ai_tools=).call(%i[copilot])", "other = config", "tune(config)", "[config].each { |c| c.ai_tools = %i[copilot] }"
    ]
    reflective.each do |write|
      it "reports #{write.inspect} against every selection key, and answers from the YAML" do
        write("config/initializers/rails_ai_context.rb", configure("  config.ai_tools = %i[codex]\n  #{write}"))
        settings = read

        expect(settings.ai_tools).to eq(%i[cursor]), write
        expect(settings.refusals.reject(&:stops_static?)).to include(have_attributes(line: 2 + write.lines.size, key: nil)), write
        expect(settings.written_in(:tool_mode)).to eq("config/initializers/rails_ai_context.rb")
      end
    end

    it "keeps a list that hides things no looser than the literals it read, whatever it cannot follow" do
      excluded = lambda do |body|
        write("config/initializers/rails_ai_context.rb", configure(body))
        read.config.excluded_models
      end

      expect(excluded.("  config.excluded_models = %w[A]\n  config.excluded_models.push(\"AdminUser\")")).to eq(%w[A AdminUser])
      expect(excluded.("  config.excluded_models = %w[A]\n  models = config.excluded_models\n  models << \"AdminUser\"")).to eq(%w[A])
      expect(excluded.("  config.excluded_models = %w[A]\n  config.tap { |c| c.excluded_models = [] }")).to eq(%w[A])
      expect(excluded.("  config.excluded_models = %w[A]\n  config.excluded_models = %w[B] if ENV[\"X\"]")).to eq(%w[A B])
      expect(excluded.("  config.excluded_models = %w[A]\n  config.excluded_models = Hidden.names")).to eq(%w[A])
      expect(excluded.("  config.excluded_models += %w[B]")).to eq(%w[FromYaml B])
      expect(excluded.("  config.excluded_models << \"B\" if ENV[\"X\"]")).to eq(%w[FromYaml B])
      expect(excluded.("  config.excluded_models = %w[A]\n  config.excluded_models.delete(\"A\")")).to eq([])
    end

    # A call that hands back one of the list's own Strings is a read only when nothing changes what it returns.
    it "reports an element of a list taken and then changed in place, and keeps what it read" do
      excluded = lambda do |use|
        write("config/initializers/rails_ai_context.rb", configure("  config.excluded_models = %w[A]\n  #{use}"))
        settings = read
        [ settings.config.excluded_models, settings.refusals.reject(&:stops_static?).map(&:key) ]
      end

      [ "config.excluded_models.first << 'x'", "config.excluded_models.last.concat('x')", "config.excluded_models.min << 'x'",
        "config.excluded_models.max.replace('x')", "config.excluded_models.sort.first << 'x'", "config.excluded_models.uniq.first << 'x'",
        "config.excluded_models.dup.first << 'x'", "config.excluded_models.reverse.last.insert(0, 'x')",
        "config.excluded_models.take(1).first.upcase!", "config.excluded_models.first.to_s << 'x'", "config.excluded_models.first.then { |s| s << 'x' }",
        "config.excluded_models.dup.concat(['x']).first << 'x'", "config.excluded_models.dup.push('x').last.upcase!",
        "name = config.excluded_models.first" ].each do |use|
        expect(excluded.(use)).to eq([ %w[A], [ :excluded_models ] ]), use
      end
      [ "config.excluded_models.first.size", "config.excluded_models.dup.size", "config.excluded_models.dup << 'x'",
        "config.excluded_models.sort.push('x')", "puts 'a' if config.excluded_models.first == 'A'",
        "puts 'a' if config.excluded_models.sort.last.include?('A')", "config.excluded_models.first.to_s.size" ].each do |use|
        expect(excluded.(use)).to eq([ %w[A], [] ]), use
      end
    end

    it "refuses nothing for a selection key read for its value alone, in a condition or as a call's receiver" do
      write("config/initializers/rails_ai_context.rb",
            configure("  config.ai_tools = %i[codex]\n  puts \"on\" if config.ai_tools.include?(:codex) && config.tool_mode == :mcp\n  puts \"#\{config.ai_tools}\""))

      expect(read.refusals).to be_empty
    end
  end

  # Each literal is what Ruby reads from it: the same text the boot's setter is given.
  it "reads the escapes inside a literal's text as Ruby does" do
    cases = {
      '%w[co\\ dex a\\nb c\\\\d]' => [ "co dex", "a\\nb", "c\\d" ],
      '%i[co\\ dex]' => [ :"co dex" ],
      '%w(a\\)b a\\(b)' => [ "a)b", "a(b" ],
      '["a\\nb\\t", "\\u00e9\\x41\\\\", :"c\\td"]' => [ "a\nb\t", "\u00e9A\\", :"c\td" ],
      "['e\\nf', 'g\\'h\\\\']" => [ "e\\nf", "g'h\\" ],
      "%q(a\\)b)" => [ "a)b" ]
    }
    cases.each do |source, expected|
      write("config/initializers/rails_ai_context.rb", configure("  config.excluded_models = #{source}"))
      value = read.config.excluded_models
      expect(value).to eq(expected), source
      expect(value.map(&:class)).to eq(expected.map(&:class)), source
    end
    write("config/initializers/rails_ai_context.rb", configure("  config.excluded_models = %w[co\\ dex other]\n  config.excluded_models.delete(\"co dex\")"))
    expect(read.config.excluded_models).to eq(%w[other])
  end

  it "reports a control or meta escape it does not undo, in a string, a symbol and a list" do
    [ '"\\M-a"', '"\\C-a"', '"\\ca"', ':"\\C-a"', '["A", "\\C-a"]' ].each do |source|
      write("config/initializers/rails_ai_context.rb", configure("  config.excluded_models = #{source}"))
      settings = read

      expect(settings.refusals.map(&:key)).to eq([ :excluded_models ]), source
      expect(settings.config.excluded_models.map(&:to_s)).not_to include("M-a", "C-a", "ca"), source
    end
  end

  it "reads a write inside the generated initializer's guard, and none under the statement's own condition" do
    write("config/initializers/rails_ai_context.rb",
          "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)\n" \
          "  RailsAiContext.configure do |config|\n    config.ai_tools = %i[cursor]\n" \
          "    config.context_files = false if ENV[\"NO_FILES\"]\n  end\nend\n")
    settings = read

    expect(settings.ai_tools).to eq(%i[cursor])
    expect(settings.context_files).to be_nil
    expect(settings.assigned?(:context_files)).to be(true)
  end

  it "reads an app whose initializer names are not ASCII under the C locale, in a root spelled in ASCII or not, however it is tagged" do
    script = <<~'RUBY'
      require "rails_ai_context"
      [ ARGV[0], ARGV[0].b, ARGV[0].dup.force_encoding(Encoding::UTF_8) ].each do |root|
        settings = RailsAiContext::UnbootedSettings.read(root)
        p [ settings.ai_tools, settings.config.sensitive_patterns.include?("config/na\u00EFve.yml"), settings.refusals.size ]
      end
    RUBY
    [ "café app", "plain app" ].each do |folder|
      root = File.join(@root, folder)
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      File.write(File.join(root, "config/initializers/réglages.rb"),
                 "# Ünïcode\nRailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\n  config.sensitive_patterns << \"config/naïve.yml\"\nend\n")
      # An empty PATH reads the files by the walk, as without ripgrep.
      [ {}, { "PATH" => "" } ].each do |path|
        out, status = Open3.capture2e({ "LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => "C", **path }, RbConfig.ruby, "-I",
                                      File.expand_path("../../../lib", __dir__), "-e", script, root)

        expect(status).to be_success, out
        expect(out.lines.map(&:chomp)).to eq([ "[[:claude], true, 0]" ] * 3), [ folder, path ].inspect
      end
    end
  end

  it "reports a YAML file that does not parse, and leaves it as it is" do
    text = "ai_tools: [claude\nhttp_port: 7000\n"
    write(".rails-ai-context.yml", text)
    settings = read

    expect(settings.ai_tools).to be_nil
    expect { settings.config }.to output(/invalid YAML/).to_stderr
    expect(settings.refusals).to contain_exactly(have_attributes(file: ".rails-ai-context.yml", key: nil))
    expect(settings.static_refusal).to be_nil
    expect(File.read(File.join(@root, ".rails-ai-context.yml"))).to eq(text)
  end

  it "reports a YAML file it cannot open" do
    write(".rails-ai-context.yml", "ai_tools: [claude]\n")
    path = File.join(@root, ".rails-ai-context.yml")
    File.chmod(0o000, path)
    skip "the file is readable to this user" if File.readable?(path)

    expect { expect(read.refusals).to contain_exactly(have_attributes(file: ".rails-ai-context.yml", reason: /could not be read/)) }
      .to output(/could not be read/).to_stderr
  ensure
    File.chmod(0o644, path) if path
  end

  # init reads the selection before the app's bundle is set up, when Prism, a gem the bundle locks, must not load yet.
  it "answers the selection with no Prism and no framework loaded" do
    write(".rails-ai-context.yml", "tool_mode: cli\n")
    write("config/initializers/rails_ai_context.rb", configure("  config.ai_tools = %i[claude]"))
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require_relative #{File.join(lib, 'rails_ai_context/unbooted_settings').inspect}
      settings = RailsAiContext::UnbootedSettings.read(ARGV[0])
      p [settings.ai_tools, settings.tool_mode, settings.context_files]
      p $LOADED_FEATURES.grep(%r{/(prism|zeitwerk|active_support|concurrent)[/.]}).first
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-e", script, @root)

    expect(status).to be_success, out
    expect(out.lines.map(&:chomp)).to eq([ "[[:claude], :cli, nil]", "nil" ])
  end

  it "says what keeps a literal unread: the condition, the later block, or a value computed at boot" do
    write("config/initializers/a.rb", configure("  config.tool_mode = :cli if ENV[\"X\"]\n  later = proc { config.server_name = \"x\" }\n" \
                                                "  config.cache_ttl = ENV.fetch(\"TTL\")"))
    write("config/environments/development.rb", "Rails.application.configure do\n  config.rails_ai_context.http_port = 7123\nend\n")
    reasons = read.refusals.to_h { |refusal| [ refusal.key, refusal.reason ] }

    expect(reasons[:tool_mode]).to include("under a condition or in a block that runs later")
    expect(reasons[:server_name]).to include("under a condition or in a block that runs later")
    expect(reasons[:cache_ttl]).to include("computed at boot")
    expect(reasons[:http_port]).to include("config.rails_ai_context")
    expect(reasons.values_at(:tool_mode, :server_name, :http_port).join).not_to include("computed")
  end

  it "reads a negative number as that number" do
    write("config/initializers/a.rb", configure("  config.hydration_max_hints = -1\n  config.live_reload_debounce = -0.5"))
    reasons = read.refusals.to_h { |refusal| [ refusal.key, refusal.reason ] }

    expect(reasons[:hydration_max_hints]).to eq("hydration_max_hints must be zero or more (got -1)")
    expect(reasons[:live_reload_debounce].to_s).not_to include("computed")
  end

  it "keeps a name that is no AI tool, as the boot does" do
    write(".rails-ai-context.yml", "ai_tools: [claude, emacs]\n")
    booted = RailsAiContext::Configuration.new.tap(&:config_file_applied!)
    RailsAiContext::Configuration.load_from_yaml(File.join(@root, ".rails-ai-context.yml"), booted)

    expect([ read.ai_tools, read.config.ai_tools ]).to eq([ booted.ai_tools, booted.ai_tools ])
    expect(read.ai_tools).to eq(%i[claude emacs])
  end

  # The boot runs these files for real; the reader has to give each key the same answer.
  it "gives the answer a full boot gives for a bare write in application.rb, an environment file and an initializer" do
    write("config/application.rb", <<~RUBY)
      require "rails"
      require "rails_ai_context"
      module Probe
        class Application < Rails::Application
          config.eager_load = false
          config.root = File.expand_path("..", __dir__)
          RailsAiContext.configuration.server_name = "from-application"
        end
      end
    RUBY
    write("config/environment.rb", "require_relative \"application\"\nRails.application.initialize!\n")
    write("config/environments/development.rb", "Rails.application.configure do\n  RailsAiContext.configuration.cache_ttl = 7\nend\n")
    write("config/initializers/probe.rb", "RailsAiContext.configuration.http_port = 7123\n")
    write(".rails-ai-context.yml", "server_name: from-yaml\ncache_ttl: 99\nhttp_port: 7999\n")
    script = <<~RUBY
      require File.join(ARGV[0], "config/environment")
      c = RailsAiContext.configuration
      u = RailsAiContext::UnbootedSettings.read(ARGV[0]).config
      puts JSON.dump([ [ c.server_name, c.cache_ttl, c.http_port ], [ u.server_name, u.cache_ttl, u.http_port ] ])
    RUBY
    out, err, status = Open3.capture3({ "RAILS_ENV" => "development", "RACK_ENV" => nil }, RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__),
                                      "-rjson", "-e", script, @root)

    expect(status).to be_success, err
    expect(JSON.parse(out.lines.last)).to eq([ [ "from-application", 7, 7123 ] ] * 2)
  end
end
