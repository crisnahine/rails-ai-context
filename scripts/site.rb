#!/usr/bin/env ruby
# frozen_string_literal: true

# The website: the files under site/, filled in from this repository and
# written to the one directory GitHub Pages serves.
#
# Nothing on the page is typed in twice. The answers it shows are recorded by
# running the gem's own binary against site/sample_app while the site builds,
# the tool list and the counts come from the registry and the introspector
# map, the install prompt is the one docs/PROMPTS.md recommends, and every
# page under docs/ is rendered with the same layout. A placeholder nothing
# fills, a heading a quoted block has lost, a tool the docs page files under
# no category, a docs page the navigation does not place, or a tool call that
# fails stops the build instead of shipping braces or a stale answer.
#
#   bundle exec ruby scripts/site.rb _site

require "cgi"
require "fileutils"
require "open3"
require "pathname"
require "rbconfig"

module Site
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.join(ROOT, "site")
  SAMPLE_APP = "site/sample_app"
  REPO = "https://github.com/crisnahine/rails-ai-context"
  # Left in a build so a later one knows the directory is its own to replace; Pages serves no dot file.
  MARK = ".rails-ai-context-site"

  # The answers the page shows: one call each, against the sample app, in the static tier.
  CALLS = {
    "schema" => %w[schema --table users],
    "model_details" => %w[model_details --model Article],
    "controllers" => %w[controllers --controller admin/articles],
    "routes" => %w[routes],
    "trace" => %w[search_code --pattern publishable? --match_type trace],
    "test_info" => %w[test_info],
    "onboard" => %w[onboard]
  }.freeze

  # The docs pages in the order the navigation lists them, with the short name
  # it shows. A page under docs/ that is not placed here, or placed here and
  # gone, stops the build.
  DOC_NAV = {
    "index" => "Overview", "QUICKSTART" => "Quickstart", "PROMPTS" => "Copy-paste prompts", "SETUP" => "AI tool setup",
    "GUIDE" => "Complete guide", "TOOLS" => "Tools reference", "RECIPES" => "Recipes", "CLI" => "CLI reference",
    "STANDALONE" => "Standalone mode", "CONFIGURATION" => "Configuration", "CUSTOM_TOOLS" => "Custom tools",
    "ARCHITECTURE" => "Architecture", "INTROSPECTORS" => "Introspectors", "SECURITY" => "Security model",
    "COMPATIBILITY" => "Compatibility", "TROUBLESHOOTING" => "Troubleshooting", "FAQ" => "FAQ"
  }.freeze
  DOC_ORDER = DOC_NAV.keys.freeze
  # Read in the repository alone: the release checklist is for maintainers.
  DOC_UNLISTED = %w[RELEASING].freeze

  # The hero plate: a few sections of the model answer, kept as the tool
  # printed them. A key number marks the lines the caption explains, and a
  # count keeps that many of the list items under a heading.
  PLATE = [
    [ 1, /\A# /, 0 ],
    [ 2, /\A## Columns/, 2 ],
    [ 3, /\A## Associations/, 2 ],
    [ 4, /\A## Validations/, 2 ],
    [ 5, /\A## Scopes/, 2 ],
    [ 6, /\A_Next:/, 0 ]
  ].freeze

  # The elements a rendered docs page may hold. Anything else is a placeholder that lost its backticks.
  HTML_ELEMENTS = %w[
    a abbr article aside b blockquote br code col colgroup dd del details div dl dt em figcaption figure
    h1 h2 h3 h4 h5 h6 hr i img ins kbd li ol p picture pre section small source span strong sub summary
    sup table tbody td tfoot th thead tr u ul var
  ].freeze

  MERMAID_LOADER = <<~HTML
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      const dark = document.documentElement.dataset.theme === "dark" || (!document.documentElement.dataset.theme && matchMedia("(prefers-color-scheme: dark)").matches);
      mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "neutral" });
      for (const code of document.querySelectorAll("code.language-mermaid")) {
        const pre = document.createElement("pre");
        pre.className = "mermaid";
        pre.textContent = code.textContent;
        code.closest("pre").replaceWith(pre);
      }
      mermaid.run();
    </script>
  HTML

  module_function

  def escape(text)
    CGI.escapeHTML(text.to_s)
  end

  # The fenced code blocks under the first heading spelled `heading`, up to the
  # next heading of its level or above, each with the info string it opened
  # with. A `#` line inside a fence is the block's, not a heading.
  def fenced_blocks(text, heading)
    blocks = []
    level = nil
    fence = nil
    open = nil
    text.each_line(chomp: true) do |line|
      if fence
        if line.strip.start_with?(fence) && line.strip.delete(fence[0]).empty?
          blocks << { lang: open[:lang], body: open[:body].join("\n") } if level
          fence = nil
        elsif level
          open[:body] << line
        end
      elsif (opened = line.match(/\A {0,3}(`{3,}|~{3,})(.*)\z/))
        fence = opened[1]
        open = { lang: opened[2].strip, body: [] }
      elsif (head = line.match(/\A(\#{1,6}) (.*)\z/))
        break if level && head[1].length <= level

        level = head[1].length if level.nil? && head[2].strip == heading
      end
    end
    blocks
  end

  # Every placeholder filled in one pass, so braces inside a quoted block stay
  # as they are: `{{name}}` from `values`, which is markup already, and
  # `{{block FILE "HEADING" N}}` as the Nth fenced block under that heading in
  # FILE, escaped. A placeholder nothing fills is refused.
  def fill(template, values, read)
    template.gsub(/\{\{block (\S+) "([^"]+)" (\d+)\}\}|\{\{(\w+)\}\}/) do
      file, heading, n, name = Regexp.last_match.captures
      if name
        values.fetch(name) { raise "the page asks for {{#{name}}}, which the build does not fill" }
      else
        block = fenced_blocks(read.call(file), heading)[n.to_i]
        raise "#{file} has no fenced block #{n} under the heading \"#{heading}\"" if block.nil?

        escape(block[:body])
      end
    end
  end

  # Each answer the page shows, recorded by running the gem's own binary on the
  # sample app in the static tier, as it answers an app that cannot boot.
  def record_answers(root: ROOT, app: SAMPLE_APP, calls: CALLS)
    calls.to_h do |key, args|
      command = [ RbConfig.ruby, "-I", "lib", "exe/rails-ai-context", "--app-path", app, "tool", *args, "--no-boot" ]
      out, err, status = Open3.capture3({ "RAILS_AI_CONTEXT_NO_UPDATE_CHECK" => "1" }, *command, chdir: root)
      raise "#{command.join(' ')} failed with status #{status.exitstatus}:\n#{err}" unless status.success?
      raise "#{command.join(' ')} printed nothing" if out.strip.empty?

      [ key, { "command" => "rails-ai-context --app-path #{app} tool #{args.join(' ')} --no-boot", "text" => out.rstrip } ]
    end
  end

  def plate(answer)
    lines = answer.lines(chomp: true)
    rows = []
    PLATE.each do |key, pattern, keep|
      at = lines.index { |line| line.match?(pattern) }
      raise "the model answer has no line matching #{pattern.inspect}, which the plate's key explains" if at.nil?

      rows << [ key, lines[at] ]
      next if keep.zero?

      items = lines[(at + 1)..].take_while { |line| line.start_with?("- ") }
      items.first(keep).each { |line| rows << [ nil, line ] }
      rows << [ nil, "... #{items.size - keep} more" ] if items.size > keep
    end
    rows.map do |key, text|
      mark = key ? "<i aria-hidden=\"true\">#{key}</i>" : ""
      dim = text.start_with?("...") ? " dim" : ""
      "<span class=\"row#{dim}\">#{mark}#{escape(text)}</span>"
    end.join
  end

  def load_gem
    $LOAD_PATH.unshift(File.join(ROOT, "lib")) unless $LOAD_PATH.include?(File.join(ROOT, "lib"))
    require "rails_ai_context"
  end

  # The tools by category, as docs/TOOLS.md files them, each with the summary
  # its guide row states. A tool the page files nowhere, or a filed name the
  # registry lacks, is refused.
  def tools(tools_doc)
    load_gem
    registry = RailsAiContext::Tools::BaseTool.registered_tools.to_h { |tool| [ tool.tool_name.to_s, tool ] }
    table = tools_doc[/^## Quick navigation\n+((?:\|.*\n)+)/, 1] or raise "docs/TOOLS.md has no Quick navigation table"
    filed = table.lines.drop(2).map do |line|
      cells = line.split("|").map(&:strip).reject(&:empty?)
      link = cells[0].to_s.match(/\A\[(.+)\]\((#.+)\)\z/) or raise "docs/TOOLS.md's Quick navigation row is not a linked category: #{line.strip}"
      label, anchor = link.captures
      names = cells[1].scan(/`(\w+)`/).flatten.map { |name| "rails_#{name}" }
      [ label, anchor, names ]
    end
    unknown = filed.flat_map(&:last) - registry.keys
    raise "docs/TOOLS.md files tools the registry does not have: #{unknown.join(', ')}" unless unknown.empty?

    unfiled = registry.keys - filed.flat_map(&:last)
    raise "docs/TOOLS.md files these tools under no category: #{unfiled.join(', ')}" unless unfiled.empty?

    filed.map do |label, anchor, names|
      [ label, anchor, names.map { |name| [ name, RailsAiContext::CLI::ToolRunner.short_name(name), registry[name].guide_row.summary ] } ]
    end
  end

  # A guide row's summary, written for the tools guide, carries a little markdown: bold and code.
  def summary_markup(summary)
    escape(summary).gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>').gsub(/`([^`]+)`/, '<code>\1</code>')
  end

  def tools_markup(tools_doc)
    tools(tools_doc).map do |label, _anchor, rows|
      items = rows.map do |name, short, summary|
        "<li><a href=\"TOOLS.html##{escape(name)}\"><code>#{escape(short)}</code></a><span>#{summary_markup(summary)}</span></li>"
      end
      "<section class=\"tool-group\"><h3>#{escape(label)}</h3><ul>\n#{items.join("\n")}\n</ul></section>"
    end.join("\n")
  end

  def counts
    load_gem
    map = RailsAiContext::Introspector::INTROSPECTOR_MAP
    {
      "tools" => RailsAiContext::Tools::BaseTool.registered_tools.size.to_s,
      "introspectors" => map.size.to_s,
      "staticIntrospectors" => map.values.count { |klass| klass.static_tier != RailsAiContext::Introspectors::StaticTier::RUNTIME_ONLY }.to_s,
      "version" => RailsAiContext::VERSION
    }
  end

  # A heading's id as GitHub spells it, so a link written for the repository lands on the site too.
  def slug(text, seen)
    base = text.gsub(/<[^>]+>/, "").gsub(/&[a-z]+;|&#\d+;/, "").downcase.gsub(/[^\p{L}\p{N} _-]/, "").tr(" ", "-")
    n = seen[base]
    seen[base] = n + 1
    n.zero? ? base : "#{base}-#{n}"
  end

  # Rouge's plain formatter wraps nothing, and the one kramdown picks by default is deprecated.
  def code_formatter
    @code_formatter ||= Class.new(Rouge::Formatters::HTML) do
      def stream(tokens, &block)
        yield '<pre class="highlight"><code>'
        super
        yield "</code></pre>"
      end
    end
  end

  def render_markdown(markdown)
    require "kramdown"
    require "kramdown-parser-gfm"
    require "rouge"
    # With block HTML parsed, kramdown files <summary> as a block it never
    # sees closed and swallows the rest of the page into it; its content is a
    # line of text. Its typography is off too: a `--app-path` outside backticks
    # would come out with a dash no shell accepts.
    Kramdown::Parser::Html::Constants::HTML_CONTENT_MODEL["summary"] = :span
    document = Kramdown::Document.new(
      markdown,
      input: "GFM", hard_wrap: false, auto_ids: false, parse_block_html: true,
      smart_quotes: %w[apos apos quot quot],
      typographic_symbols: { hellip: "...", mdash: "---", ndash: "--", laquo: "&lt;&lt;", raquo: "&gt;&gt;", laquo_space: "&lt;&lt; ", raquo_space: " &gt;&gt;" },
      syntax_highlighter: "rouge", syntax_highlighter_opts: { css_class: "highlight", formatter: code_formatter }
    )
    html = document.to_html
    # A placeholder written as <name> outside backticks reaches the page as a
    # tag the browser hides, and the sentence loses its word.
    unknown = html.scan(/<([A-Za-z][\w-]*)[\s>]/).flatten.map(&:downcase).uniq - HTML_ELEMENTS
    raise "the page would carry a tag browsers do not know, which hides its text: #{unknown.map { |tag| "<#{tag}>" }.join(', ')}; write it in backticks" unless unknown.empty?

    seen = Hash.new(0)
    html = html.gsub(%r{<h([1-6])>(.*?)</h\1>}m) { "<h#{$1} id=\"#{slug($2, seen)}\">#{$2}</h#{$1}>" }
    html.gsub(%r{<blockquote>\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(?:<br />)?\s*}) do
      kind = $1.downcase
      "<blockquote class=\"alert alert-#{kind}\"><p><strong class=\"alert-title\">#{kind.capitalize}</strong>"
    end
  end

  # Every page the site renders from docs/: where it comes from, where it goes, and its title.
  def doc_pages(root: ROOT)
    top = Dir[File.join(root, "docs", "*.md")].map { |path| File.basename(path, ".md") }
    missing = DOC_ORDER - top
    raise "docs/ has no page for #{missing.join(', ')}, which the navigation lists" unless missing.empty?

    unplaced = top - DOC_ORDER - DOC_UNLISTED
    raise "docs/#{unplaced.join('.md, docs/')}.md is not placed in the navigation (Site::DOC_ORDER)" unless unplaced.empty?

    pages = DOC_ORDER.map { |name| page_for("docs/#{name}.md", root) }
    pages + Dir[File.join(root, "docs", "adr", "*.md")].sort.map { |path| page_for(Pathname(path).relative_path_from(Pathname(root)).to_s, root) }
  end

  def page_for(source, root)
    text = File.read(File.join(root, source))
    title = text[/^# (.+)$/, 1].to_s.gsub(/[`*]/, "").strip
    out = source == "docs/index.md" ? "docs.html" : source.delete_prefix("docs/").sub(/\.md\z/, ".html")
    { source: source, out: out, title: title.empty? ? File.basename(source, ".md") : title }
  end

  # A relative link in a doc, as the site serves it: another doc becomes its
  # page, and anything else points into the repository at the built commit,
  # the file itself for an image and the page around it for a link.
  def rewrite_links(html, pages, from:, commit:)
    here = Pathname(from[:out]).dirname
    html.gsub(/\b(href|src)="([^"]+)"/) do
      attr, target = Regexp.last_match.captures
      next "#{attr}=\"#{target}\"" if target.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|#|//)})

      path, anchor = target.split("#", 2)
      resolved = (Pathname(from[:source]).dirname + CGI.unescapeHTML(path)).cleanpath.to_s
      page = pages.find { |candidate| candidate[:source] == resolved }
      url = if page
        Pathname(page[:out]).relative_path_from(here).to_s
      else
        "#{REPO}/#{attr == 'src' ? 'raw' : 'blob'}/#{commit}/#{resolved}"
      end
      "#{attr}=\"#{url}#{anchor ? "##{anchor}" : ''}\""
    end
  end

  def render_doc(page, pages, template, values, root: ROOT, commit:)
    text = File.read(File.join(root, page[:source])).sub(/\A---\n.*?\n---\n/m, "")
    content = rewrite_links(render_markdown(text), pages, from: page, commit: commit)
    prefix = Pathname(".").relative_path_from(Pathname(page[:out]).dirname).to_s
    prefix = prefix == "." ? "" : "#{prefix}/"
    nav = pages.first(DOC_ORDER.size).zip(DOC_NAV.values).map do |entry, label|
      current = entry == page ? ' aria-current="page"' : ""
      "<li><a href=\"#{prefix}#{entry[:out]}\"#{current}>#{escape(label)}</a></li>"
    end.join("\n")
    description = text.lines.map(&:strip).find { |line| line.match?(/\A\*\*.+\*\*\z/) }.to_s.delete("*")
    fill(template, values.merge(
      "title" => escape(page[:title]),
      "description" => escape(description.empty? ? "#{page[:title]}: rails-ai-context documentation." : description),
      "content" => content,
      "docsNav" => nav,
      "mermaid" => content.include?('class="language-mermaid"') ? MERMAID_LOADER : "",
      "root" => prefix,
      "source" => escape(page[:source]),
      "sourceUrl" => "#{REPO}/blob/#{commit}/#{page[:source]}"
    ), ->(file) { File.read(File.join(root, file)) })
  end

  # Write the site to `out`: the landing page filled in, each docs page
  # rendered, the other files of site/ as they are, and the brand assets the
  # pages name. `out` must be new or a directory this wrote before, since it is
  # emptied first. Returns the files written, relative to `out`.
  def build(out:, answers:, commit:, root: ROOT)
    if File.exist?(out)
      raise "#{out} is there and was not written by this script, so it is left alone: give a new directory" unless File.exist?(File.join(out, MARK))

      FileUtils.rm_rf(out)
    end
    read = ->(file) { File.read(File.join(root, file)) }
    values = counts.merge("commit" => escape(commit), "commitShort" => escape(commit[0, 7]), "repo" => REPO,
                          "sampleApp" => "#{REPO}/tree/#{commit}/#{SAMPLE_APP}")
    answers.each do |key, answer|
      values["answer_#{key}"] = escape(answer["text"])
      values["command_#{key}"] = escape(answer["command"])
    end
    missing = CALLS.keys - answers.keys
    raise "no answer recorded for #{missing.join(', ')}" unless missing.empty?

    values["plate"] = plate(answers.fetch("model_details")["text"])
    values["toolList"] = tools_markup(read.call("docs/TOOLS.md"))

    FileUtils.mkdir_p(out)
    File.write(File.join(out, MARK), "")
    File.write(File.join(out, ".nojekyll"), "")
    written = [ "index.html" ]
    File.write(File.join(out, "index.html"), fill(read.call("site/index.html"), values, read))

    pages = doc_pages(root: root)
    template = read.call("site/docs.html")
    pages.each do |page|
      FileUtils.mkdir_p(File.join(out, File.dirname(page[:out])))
      File.write(File.join(out, page[:out]), render_doc(page, pages, template, values, root: root, commit: commit))
      written << page[:out]
    end

    # The page's own files: the stylesheet, the script, and nothing a build
    # left behind (a dot file, the sample app, the two templates).
    Dir.children(File.join(root, "site")).sort.each do |name|
      path = File.join(root, "site", name)
      next if name.start_with?(".") || %w[index.html docs.html].include?(name) || !File.file?(path)

      FileUtils.cp(path, File.join(out, name))
      written << name
    end
    %w[icon.svg logo-light.svg logo-dark.svg social-preview.png].each do |name|
      FileUtils.cp(File.join(root, "docs", "assets", name), File.join(out, name))
      written << name
    end
    written
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.size != 1
    warn "usage: bundle exec ruby scripts/site.rb <out>"
    exit 2
  end
  begin
    commit, status = Open3.capture2("git", "-C", Site::ROOT, "rev-parse", "HEAD")
    raise "git rev-parse HEAD failed, so the page cannot say what it was built from" unless status.success? && commit.strip.match?(/\A\h{40}\z/)

    commit = commit.strip
    answers = Site.record_answers
    out = File.expand_path(ARGV[0])
    written = Site.build(out: out, answers: answers, commit: commit)
    puts "wrote the site to #{out}: #{written.size} files at #{commit[0, 7]}, #{answers.size} answers recorded from #{Site::SAMPLE_APP}"
  rescue StandardError => e
    warn "site: #{e.message}"
    exit 1
  end
end
