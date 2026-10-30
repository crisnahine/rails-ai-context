# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"

load File.expand_path("../scripts/site.rb", __dir__)

# The website is filled in from the repository, so these hold the page to what
# the repository states: the install prompt, the tool registry, the docs pages
# and their links, and the answers recorded against the sample app.
RSpec.describe "the website build" do
  root = File.expand_path("..", __dir__)
  template = File.read(File.join(root, "site", "index.html"))
  commit = "0123456789abcdef0123456789abcdef01234567"
  # The floor gemfiles carry the gem's own dependencies alone, so the examples that render docs skip there.
  no_markdown = begin
    %w[kramdown kramdown-parser-gfm rouge].each { |name| require name }
    false
  rescue LoadError => e
    "the site group is not in this bundle (#{e.message})"
  end

  # Stands in for a recorded run: the shape the tools print, short.
  answers = Site::CALLS.to_h do |key, args|
    text = key == "model_details" ? File.read(File.join(root, "spec", "fixtures", "site", "model_details.md")) : "# #{key}\n\n- one\n\n_[STATIC] stand-in_"
    [ key, { "command" => "rails-ai-context tool #{args.join(' ')}", "text" => text } ]
  end

  def scratch
    dir = Dir.mktmpdir("rails-ai-context-site-")
    yield File.join(dir, "site")
  ensure
    FileUtils.rm_rf(dir)
  end

  it "reads a fenced block under its own heading, and a hash line inside one is the block's" do
    text = [
      "# Top", "", "```markdown", "## A", "```", "",
      "## A", "", "```text", "one", "# not a heading", "```", "", "### Deeper", "", "~~~diff", "+two", "~~~", "",
      "## B", "", "````", "three", "```", "````"
    ].join("\n")

    expect(Site.fenced_blocks(text, "A")).to eq([ { lang: "text", body: "one\n# not a heading" }, { lang: "diff", body: "+two" } ])
    expect(Site.fenced_blocks(text, "B")).to eq([ { lang: "", body: "three\n```" } ])
    expect(Site.fenced_blocks(text, "Missing")).to eq([])
  end

  it "refuses a placeholder nothing fills, and leaves braces a quoted block holds" do
    read = ->(_file) { "## H\n\n```\n{{kept}} <tag>\n```\n" }

    expect { Site.fill("{{nope}}", {}, read) }.to raise_error(RuntimeError, /\{\{nope\}\}/)
    expect { Site.fill('{{block X.md "H" 2}}', {}, read) }.to raise_error(RuntimeError, /no fenced block 2/)
    expect(Site.fill('<code>{{block X.md "H" 0}}</code> {{a}}', { "a" => "b" }, read)).to eq("<code>{{kept}} &lt;tag&gt;</code> b")
  end

  it "quotes the install prompt the docs recommend, so the page and the README cannot drift from it" do
    expect(template).to include('{{block docs/PROMPTS.md "Install (recommended)" 0}}')
    expect(Site.fenced_blocks(File.read(File.join(root, "docs", "PROMPTS.md")), "Install (recommended)")).not_to be_empty
  end

  it "lists every registered tool once, under the category the tools reference files it in" do
    groups = Site.tools(File.read(File.join(root, "docs", "TOOLS.md")))
    names = groups.flat_map { |_, rows| rows.map(&:first) }

    expect(names.sort).to eq(RailsAiContext::Tools::BaseTool.registered_tools.map(&:tool_name).map(&:to_s).sort)
    expect(names.uniq.size).to eq(names.size)
    expect(groups.flat_map { |_, rows| rows.map(&:last) }).to all(match(/\S/))
  end

  it "refuses a tools reference that files a tool the registry lacks, or leaves one unfiled" do
    doc = File.read(File.join(root, "docs", "TOOLS.md"))

    expect { Site.tools(doc.sub("`search_code`", "`search_code`, `fly`")) }.to raise_error(RuntimeError, /rails_fly/)
    expect { Site.tools(doc.sub("`search_code`, ", "")) }.to raise_error(RuntimeError, /under no category: rails_search_code/)
  end

  it "counts what the registry, the introspector map and the configuration hold" do
    counts = Site.counts

    expect(counts["tools"]).to eq(RailsAiContext::Tools::BaseTool.registered_tools.size.to_s)
    expect(counts["introspectors"]).to eq(RailsAiContext::Introspector::INTROSPECTOR_MAP.size.to_s)
    expect(counts["staticIntrospectors"].to_i).to be_between(1, counts["introspectors"].to_i - 1)
    expect(counts["standardPreset"]).to eq(RailsAiContext::Configuration::PRESETS[:standard].size.to_s)
    expect(counts["maxChars"]).to match(/\A\d{1,3}(,\d{3})*\z/)
    expect(counts["maxChars"].delete(",").to_i).to eq(RailsAiContext::Configuration.new.max_tool_response_chars)
    expect(counts["rootBudget"].delete(",").to_i).to eq(RailsAiContext::Serializers::Budget::BYTES[:root])
    expect(counts["version"]).to eq(RailsAiContext::VERSION)
  end

  it "states in the README the counts the code holds" do
    readme = File.read(File.join(root, "README.md"))
    counts = Site.counts
    matrix = YAML.load_file(File.join(root, ".github", "workflows", "unit-matrix.yml")).dig("jobs", "test", "strategy", "matrix")
    pairs = matrix["ruby"].size * matrix["rails"].size - matrix["exclude"].size

    expect(readme).to include("#{counts['introspectors']} introspectors", "#{counts['staticIntrospectors']} of the #{counts['introspectors']} introspectors")
    expect(readme).to include("`:full` runs all #{counts['introspectors']} and `:standard` runs #{counts['standardPreset']}")
    expect(readme).to include("#{pairs} Ruby and Rails pairs", "`max_tool_response_chars`, #{counts['maxChars']}", "#{counts['rootBudget']} bytes")
    expect(readme.scan(/\b(\d+) introspectors\b/).flatten.uniq).to eq([ counts["introspectors"] ])
  end

  it "draws the plate from the model answer's own lines, with a key number on each kind of fact" do
    plate = Site.plate(answers.fetch("model_details")["text"])
    rows = plate.scan(%r{<span class="row[^"]*">(?:<i aria-hidden="true">\d+</i>)?(.*?)</span>}).flatten.map { |row| CGI.unescapeHTML(row) }

    expect(plate.scan(%r{<i aria-hidden="true">(\d+)</i>}).flatten).to eq(%w[1 2 3 4 5 6])
    expect(rows.reject { |row| row.start_with?("...") }).to all(satisfy { |row| answers["model_details"]["text"].include?(row) })
    expect(rows).to include(a_string_starting_with("... "))
  end

  it "refuses a model answer that lost a section the plate's key explains, or whose section is empty" do
    text = answers.fetch("model_details")["text"]

    expect { Site.plate(text.sub("## Scopes", "## Named scopes")) }.to raise_error(RuntimeError, /no line matching/)
    expect { Site.plate(text.sub(/## Scopes\n(- .*\n)+/, "## Scopes\n\n")) }.to raise_error(RuntimeError, /Scopes section holds no list item/)
  end

  it "spells a heading's id as GitHub does, so a link written for the repository lands" do
    seen = Hash.new(0)

    expect(Site.slug("Schema &amp; Models", seen)).to eq("schema--models")
    expect(Site.slug("<code>rails_get_schema</code>", seen)).to eq("rails_get_schema")
    expect(Site.slug("Install (recommended)", seen)).to eq("install-recommended")
    expect(Site.slug("Install (recommended)", seen)).to eq("install-recommended-1")
  end

  it "places every docs page in the navigation, and refuses one it does not place" do
    pages = Site.doc_pages
    tops = pages.first(Site::DOC_ORDER.size)

    expect(tops.map { |page| page[:source] }).to eq(Site::DOC_ORDER.map { |name| "docs/#{name}.md" })
    expect(tops.map { |page| page[:out] }).to include("docs.html", "TOOLS.html")
    expect(pages.map { |page| page[:out] }).to include("RELEASING.html", a_string_starting_with("adr/"), a_string_starting_with("agents/"))
    expect(tops.map { |page| page[:title] }).to all(match(/\S/))
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "docs"))
      Site::DOC_ORDER.each { |name| File.write(File.join(dir, "docs", "#{name}.md"), "# #{name}\n") }
      File.write(File.join(dir, "docs", "NEW.md"), "# New\n")
      expect { Site.doc_pages(root: dir) }.to raise_error(RuntimeError, /docs\/NEW\.md is neither placed/)
    end
  end

  it "rewrites a doc's links: another doc becomes its page, a file in the repository points at the built commit" do
    pages = [ { source: "docs/CLI.md", out: "CLI.html" }, { source: "docs/TOOLS.md", out: "TOOLS.html" }, { source: "docs/adr/0001-x.md", out: "adr/0001-x.html" } ]
    html = '<a href="TOOLS.md#rails_query">a</a> <a href="adr/0001-x.md">b</a> <a href="../README.md">c</a> <a href="#here">d</a> <a href="https://example.com/x.md">e</a> <img src="assets/x.png">'
    from_adr = '<a href="../CLI.md">f</a>'

    expect(Site.rewrite_links(html, pages, from: pages[0], commit: commit)).to eq(
      "<a href=\"TOOLS.html#rails_query\">a</a> <a href=\"adr/0001-x.html\">b</a> <a href=\"#{Site::REPO}/blob/#{commit}/README.md\">c</a> <a href=\"#here\">d</a> <a href=\"https://example.com/x.md\">e</a> <img src=\"#{Site::REPO}/raw/#{commit}/docs/assets/x.png\">"
    )
    expect(Site.rewrite_links(from_adr, pages, from: pages[2], commit: commit)).to eq('<a href="../CLI.html">f</a>')
  end

  it "renders GitHub's markdown: tables, fenced code, alerts and heading ids", skip: no_markdown do
    html = Site.render_markdown("# T\n\n> [!NOTE]\n> Mind this.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```ruby\nputs 1\n```\n")

    expect(html).to include('<h1 id="t">T</h1>', '<blockquote class="alert alert-note"><p><strong class="alert-title">Note</strong>', "<table>", 'class="language-ruby highlighter-rouge"')
  end

  it "keeps a flag's dashes and straight quotes, which kramdown would otherwise set as typography", skip: no_markdown do
    expect(Site.render_markdown(%(Run --prune with "x" and 'y'... done\n))).to include(%(Run --prune with "x" and 'y'... done))
  end

  it "renders a details block whose summary kramdown would otherwise swallow the page into", skip: no_markdown do
    html = Site.render_markdown("<details>\n<summary class=\"x\">Example <b>output</b></summary>\n\n| a |\n|---|\n| 1 |\n\n</details>\n\nAfter `<summary>`.\n")

    expect(html).to include('<summary class="x">Example <b>output</b></summary>', "<table>", "</details>", "<p>After <code>&lt;summary&gt;</code>.</p>")
    expect(html).not_to include("&lt;/summary&gt;", "&lt;/details&gt;")
  end

  it "refuses a placeholder written as a tag outside backticks, which a browser would hide", skip: no_markdown do
    expect { Site.render_markdown("The <name> database stopped.\n") }.to raise_error(RuntimeError, /<name>.*backticks/)
    expect(Site.render_markdown("The `<name>` database stopped.\n")).to include("<code>&lt;name&gt;</code>")
  end

  it "builds the page filled in, every docs page, and every local file the pages name", skip: no_markdown do
    scratch do |out|
      written = Site.build(out: out, answers: answers, commit: commit)
      page = File.read(File.join(out, "index.html"))
      local = Dir[File.join(out, "**", "*.html")].flat_map do |file|
        html = File.read(file)
        expect(html).not_to match(/\{\{/), file
        html.scan(/\b(?:href|src)="([^"#:]+)(?:#[^"]*)?"/).flatten.map { |rel| File.expand_path(rel, File.dirname(file)) }
      end

      expect(written).to include("index.html", "docs.html", "TOOLS.html", "style.css", "main.mjs", "icon.svg", "social-preview.png")
      expect(page).to include(commit, RailsAiContext::VERSION, '<a href="TOOLS.html#rails_get_schema"><code>schema</code></a>')
      expect(page).to include(CGI.escapeHTML(answers["routes"]["text"]))
      expect(local.uniq).to all(satisfy { |path| File.exist?(path) })
      expect(File.exist?(File.join(out, "sample_app"))).to be(false)
      expect(File.read(File.join(out, "TOOLS.html"))).to include('id="rails_get_schema"')
      expect(File.read(File.join(out, "TOOLS.html"))).to include(%(<link rel="canonical" href="#{Site::SITE}/TOOLS.html">))

      # Search engines and AI assistants get every public page, and none of the maintainer notes.
      sitemap = File.read(File.join(out, "sitemap.xml"))
      llms = File.read(File.join(out, "llms.txt"))
      expect(written).to include("sitemap.xml", "llms.txt")
      expect(sitemap).to include("<loc>#{Site::SITE}/</loc>", "<loc>#{Site::SITE}/TOOLS.html</loc>", "/adr/0001-")
      expect(llms).to include("[Quickstart](#{Site::SITE}/QUICKSTART.html): ", "#{RailsAiContext::Tools::BaseTool.registered_tools.size} read-only tools")
      expect(sitemap + llms).not_to match(%r{/agents/|RELEASING})
      expect(File.read(File.join(out, "RELEASING.html"))).to include('<meta name="robots" content="noindex">')
      expect(File.read(File.join(out, "TOOLS.html"))).not_to include("noindex")
      expect(JSON.parse(page[%r{<script type="application/ld\+json">(.*?)</script>}m, 1])).to include("version" => RailsAiContext::VERSION)

      # A second build replaces the first, which it wrote.
      Site.build(out: out, answers: answers.merge("routes" => { "command" => "x", "text" => "second" }), commit: commit)
      expect(File.read(File.join(out, "index.html"))).to include("second")
    end
  end

  it "leaves alone a directory it did not write" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "keep.txt"), "mine")

      expect { Site.build(out: dir, answers: answers, commit: commit) }.to raise_error(RuntimeError, /was not written by this script/)
      expect(File.read(File.join(dir, "keep.txt"))).to eq("mine")
    end
  end

  it "refuses to build without every answer the page shows" do
    scratch do |out|
      expect { Site.build(out: out, answers: answers.except("routes"), commit: commit) }.to raise_error(RuntimeError, /no answer recorded for routes/)
    end
  end

  it "loads no script or style from another origin on the landing page" do
    foreign = template.scan(/<(?:script|link)\b[^>]*\b(?:src|href)="(https?:[^"]+)"/).flatten
      .reject { |url| url.start_with?("https://crisnahine.github.io/rails-ai-context/") }

    expect(foreign).to eq([])
  end

  it "records an answer by running the gem's own binary on the sample app" do
    recorded = Site.record_answers(calls: Site::CALLS.slice("schema", "trace"))

    expect(recorded.keys).to eq(%w[schema trace])
    expect(recorded["schema"]["command"]).to eq("rails-ai-context --app-path site/sample_app tool schema --table users --no-boot")
    expect(recorded["schema"]["text"]).to include("## Table: users", "[STATIC]")
    expect(recorded["trace"]["text"]).to include("app/services/article_publisher.rb")
  end

  it "refuses an answer the binary could not give, and one that names nothing the app has" do
    expect { Site.record_answers(calls: { "x" => %w[no_such_tool] }) }.to raise_error(RuntimeError, /failed with status/)
    expect { Site.record_answers(calls: { "x" => %w[controllers --controller admin/nope] }) }.to raise_error(RuntimeError, /answered a refusal.*not found/m)
    expect(Site.refused?("# Trace: `x`\n\n_No definition found for `def x`_\n")).to be(true)
    expect(Site.refused?("[UNAVAILABLE: requires a booted Rails app]")).to be(true)
    expect(Site.refused?("## Table: users\n")).to be(false)
  end

  # The README's "A closer look" quotes the gem's own answers, trimmed, and its
  # first table quotes one line each. A line the gem no longer prints fails here.
  it "quotes in the README only lines the gem prints for the sample app" do
    require "shellwords"
    readme = File.read(File.join(root, "README.md"))
    closer = readme[/^## A closer look\n(.*?)^## The tools/m, 1]
    blocks = Site.fenced_blocks("## X\n\n#{closer}", "X").map { |block| block[:body].lines(chomp: true) }
    commands = blocks.filter_map { |lines| lines.first[/\A\$ rails-ai-context --app-path site\/sample_app tool (.+?) --no-boot\z/, 1] }
    calls = commands.each_with_index.to_h { |args, i| [ "readme#{i}", Shellwords.split(args) ] }
    calls.merge!("user" => %w[model_details --model User], "articles" => %w[controllers --controller articles], "tests" => %w[test_info], "routes" => %w[routes])
    recorded = Site.record_answers(calls: calls).values.map { |answer| answer["text"] }
    quoted = blocks.flat_map { |lines| lines.drop(lines.first.start_with?("$ ") ? 1 : 0) }.reject(&:empty?)
    table = readme[/^\| When \| What the assistant gets \| A real line from an answer \|\n\|.*?\n((?:\|.*\n)+)/, 1]
    cells = table.lines.map { |row| row.split(" | ").last.delete_suffix(" |\n").strip }

    expect(commands.size).to be >= 4
    expect(cells.size).to be >= 6
    (quoted + cells.flat_map { |cell| cell.split(" · ") }).each do |line|
      expect(recorded.any? { |text| text.include?(line) }).to be(true), "the gem prints no line holding: #{line}"
    end
  end
end
