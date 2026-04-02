# frozen_string_literal: true

require "net/http"
require "uri"

module RailsAiContext
  module Tools
    class SearchDocs < BaseTool
      tool_name "rails_search_docs"
      description "Search the official Rails documentation index for guides, API docs, and tutorials. " \
        "Use when: you need to reference Rails conventions, API details, or best practices. " \
        "Pass query:\"active record callbacks\" to find matching topics. " \
        "Filter with source:\"guides\" or source:\"api\". " \
        "Set fetch:true to retrieve full content from GitHub (cached 24h)."

      input_schema(
        properties: {
          query: {
            type: "string",
            description: "Search terms (e.g. 'active record validations', 'turbo streams', 'action cable')."
          },
          source: {
            type: "string",
            enum: %w[all guides api stimulus turbo hotwire],
            description: "Filter results by documentation source. Default: all."
          },
          limit: {
            type: "integer",
            description: "Maximum number of results to return (1-20). Default: 5."
          },
          fetch: {
            type: "boolean",
            description: "When true, fetch full content from GitHub (cached 24h in tmp/). Default: false."
          }
        },
        required: [ "query" ]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: true)

      VALID_SOURCES = %w[all guides api stimulus turbo hotwire].freeze
      INDEX_PATH = File.join(File.dirname(__FILE__), "..", "data", "docs", "index.json").freeze

      def self.call(query:, source: "all", limit: 5, fetch: false, server_context: nil, **_extra)
        # Validate query
        query = query.to_s.strip
        if query.empty?
          return text_response("Query is required. Provide search terms (e.g. 'active record validations').")
        end

        # Validate source
        source = source.to_s.downcase
        unless VALID_SOURCES.include?(source)
          return text_response("Invalid source: '#{source}'. Valid values: #{VALID_SOURCES.join(', ')}")
        end

        # Normalize limit
        limit = limit.to_i
        limit = 5 if limit <= 0
        limit = [ limit, 20 ].min

        # Load index
        index = load_index
        return text_response(index[:error]) if index[:error]

        topics = index[:topics]

        # Detect Rails version and resolve branch
        branch = detect_rails_branch

        # Search
        # Normalize source filter: "guides" maps to the "rails" tag in the index;
        # "hotwire" is an umbrella covering stimulus, turbo, and hotwire_native.
        source_tags = case source
        when "guides"  then %w[rails guides]
        when "hotwire" then %w[stimulus turbo hotwire hotwire_native]
        else           [ source ]
        end

        tokens = query.downcase.split(/\s+/)
        scored = topics.filter_map do |topic|
          next if source != "all" && !source_tags.include?(topic["source"]&.downcase)

          score = compute_score(tokens, topic)
          next if score <= 0

          { topic: topic, score: score }
        end

        scored.sort_by! { |s| -s[:score] }
        results = scored.first(limit)

        if results.empty?
          return text_response("No documentation found for '#{query}'. Try broader terms like 'active record', 'routing', or 'testing'.")
        end

        if fetch
          format_fetch_results(results, query, source, branch)
        else
          format_results(results, query, source, branch)
        end
      end

      class << self
        private

        def load_index
          return @docs_index if @docs_index&.dig(:topics)

          result = begin
            unless File.exist?(INDEX_PATH)
              return { error: "Documentation index not found at #{INDEX_PATH}. The gem installation may be incomplete — reinstall rails-ai-context." }
            end

            raw = File.read(INDEX_PATH, encoding: "bom|utf-8")
            data = JSON.parse(raw)
            topics = data.is_a?(Array) ? data : (data["topics"] || [])
            { topics: topics }
          rescue JSON::ParserError => e
            { error: "Failed to parse documentation index: #{e.message}" }
          end

          # Only memoize successful results so transient failures can be retried
          @docs_index = result if result[:topics]
          result
        end

        def detect_rails_branch
          lock_path = Rails.root.join("Gemfile.lock").to_s
          return "main" unless File.exist?(lock_path)

          content = File.read(lock_path, encoding: "bom|utf-8")
          if (match = content.match(/railties\s+\((\d+\.\d+)/))
            "#{match[1].tr('.', '-')}-stable"
          else
            "main"
          end
        rescue => e
          $stderr.puts "[rails-ai-context] detect_rails_branch failed: #{e.message}" if ENV["DEBUG"]
          "main"
        end

        def compute_score(tokens, topic)
          title = (topic["title"] || "").downcase
          summary = (topic["summary"] || "").downcase
          keywords = Array(topic["keywords"]).map(&:downcase)

          score = 0
          tokens.each do |token|
            score += 10 if title.include?(token)
            score += 5 if summary.include?(token)
            score += 1 if keywords.any? { |k| k.include?(token) }
          end
          score
        end

        # Derive URL at runtime — no hardcoded URLs stored in index.json
        def url_for(topic, branch)
          case topic["source"]
          when "rails"
            "https://raw.githubusercontent.com/rails/rails/#{branch}/guides/source/#{topic["id"]}.md"
          when "turbo"
            "https://raw.githubusercontent.com/hotwired/turbo-site/main/#{topic["path"]}"
          when "stimulus"
            "https://raw.githubusercontent.com/hotwired/stimulus/main/#{topic["path"]}"
          when "hotwire_native"
            "https://raw.githubusercontent.com/hotwired/turbo-site/main/#{topic["path"]}"
          else
            nil
          end
        end

        def format_results(results, query, source, branch)
          lines = []
          lines << "# Rails Documentation Search: \"#{query}\""
          lines << "Found #{results.size} results (#{source})"
          lines << ""

          results.each_with_index do |r, i|
            topic = r[:topic]
            url = url_for(topic, branch)
            lines << "## #{i + 1}. #{topic['title']} [#{topic['source']}]"
            lines << topic["summary"] if topic["summary"]
            lines << "→ #{url}"
            lines << ""
          end

          text_response(lines.join("\n"))
        end

        def format_fetch_results(results, query, source, branch)
          lines = []
          lines << "# Rails Documentation Search: \"#{query}\" (fetched)"
          lines << "Found #{results.size} results (#{source})"
          lines << ""

          results.each_with_index do |r, i|
            topic = r[:topic]
            url = url_for(topic, branch)
            lines << "## #{i + 1}. #{topic['title']} [#{topic['source']}]"

            content = fetch_content(topic, branch, url)
            lines << content
            lines << ""
          end

          text_response(lines.join("\n"))
        end

        def fetch_content(topic, branch, url)
          cache_dir = Rails.root.join("tmp", "rails-ai-context", "docs")
          FileUtils.mkdir_p(cache_dir)

          cache_key = "#{topic['id']}_#{branch}.md"
          cache_file = cache_dir.join(cache_key)

          # Use cached file if < 24 hours old
          if File.exist?(cache_file) && (Time.now - File.mtime(cache_file)) < 86_400
            return File.read(cache_file, encoding: "bom|utf-8")
          end

          # Fetch from GitHub
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 10
          http.read_timeout = 10

          request = Net::HTTP::Get.new(uri)
          response = http.request(request)

          max_fetch_bytes = 2_000_000 # 2MB safety cap
          if response.is_a?(Net::HTTPSuccess)
            body = response.body
            body = body.byteslice(0, max_fetch_bytes) if body.bytesize > max_fetch_bytes
            File.write(cache_file, body)
            body
          else
            "#{topic['summary']}\n→ #{url}\n_(fetch failed: HTTP #{response.code})_"
          end
        rescue => e
          "#{topic['summary']}\n→ #{url}\n_(fetch failed: #{e.message})_"
        end
      end
    end
  end
end
