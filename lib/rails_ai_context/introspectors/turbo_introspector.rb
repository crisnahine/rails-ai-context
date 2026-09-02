# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans for Hotwire/Turbo usage: frames, streams, model broadcasts.
    class TurboIntrospector
      extend StaticTier
      static_tier :files_only

      MODEL_BROADCAST_MACROS = %w[broadcasts broadcasts_to broadcasts_refreshes broadcasts_refreshes_to].freeze
      BROADCAST_CALL = /\Abroadcast_\w+_to\z/
      BROADCAST_KINDS = %w[app/controllers app/models app/services app/jobs app/workers app/channels].freeze

      # A mention of these helpers anywhere in a controller is the signal,
      # whether called, referenced or guarded. Vocabulary, not structure, so
      # regex rather than a listener.
      NATIVE_HELPER = /turbo_native_app\?|hotwire_native_app\?/
      NATIVE_NAVIGATION = Regexp.union(%w[
        recede_or_redirect_to resume_or_redirect_to refresh_or_redirect_to
        recede_or_redirect_back_or_to resume_or_redirect_back_or_to refresh_or_redirect_back_or_to
      ])

      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        broadcasts = scan_broadcasts
        {
          turbo_frames: extract_turbo_frames,
          turbo_streams: extract_turbo_stream_templates,
          stream_actions: extract_stream_actions,
          model_broadcasts: broadcasts[:models],
          explicit_broadcasts: broadcasts[:explicit],
          stream_subscriptions: extract_stream_subscriptions,
          morph_meta: detect_morph_meta,
          permanent_elements: extract_permanent_elements,
          turbo_drive_settings: extract_turbo_drive_settings,
          turbo_stream_responses: extract_turbo_stream_responses,
          turbo_native: detect_turbo_native
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def views_dir
        File.join(root, "app/views")
      end

      def extract_turbo_frames
        frames = []
        each_view_line do |file, line, line_num|
          next unless line.include?("turbo_frame_tag")

          frames << { id: frame_id(line), src: frame_src(line), file: file, line: line_num, snippet: line.strip }
        end
        frames
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_frames failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_stream_subscriptions
        subscriptions = []
        each_view_line do |file, line, line_num|
          next unless line.include?("turbo_stream_from")

          subscriptions << { stream: subscription_stream(line), file: file, line: line_num, snippet: line.strip }
        end
        subscriptions
      rescue => e
        $stderr.puts "[rails-ai-context] extract_stream_subscriptions failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Views are not Ruby, so they are read line by line. Files are yielded
      # in path order with their root-relative name and 1-based line.
      def each_view_line
        return unless Dir.exist?(views_dir)

        real_views = File.realpath(views_dir)
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).sort.each do |path|
          real = File.realpath(path)
          next unless SafePath.contained?(real, real_views)

          content = RailsAiContext::SafeFile.read(real) or next
          file = path.sub("#{root}/", "")
          content.each_line.with_index(1) { |line, line_num| yield file, line, line_num }
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          next
        end
      end

      # The first argument as written, minus a symbol colon or string quotes:
      # `:post` and `"post"` are the frame `post`, while `dom_id(@post, :edit)`
      # stays whole because the split happens at a top-level comma only.
      def frame_id(line)
        match = line.match(/turbo_frame_tag\s+(.+?)\s*(?:%>|\bdo\b|$)/)
        return "(dynamic)" unless match

        first = first_argument(match[1])
        return "(dynamic)" if first.empty? || first.start_with?("%") || first == "do"

        first.sub(/\A:/, "").gsub(/\A["']|["']\z/, "")
      end

      def first_argument(text)
        top_level_arguments(text).first.to_s
      end

      # Splits on commas outside any bracket, so `[a, :b]` and `f(x, :y)` stay
      # one argument.
      def top_level_arguments(text)
        args = []
        depth = 0
        start = 0
        text.each_char.with_index do |ch, i|
          case ch
          when "(", "[", "{" then depth += 1
          when ")", "]", "}" then depth -= 1
          when ","
            if depth.zero?
              args << text[start...i].strip
              start = i + 1
            end
          end
        end
        args << text[start..].to_s.strip
        args.reject(&:empty?)
      end

      def frame_src(line)
        line[/src:\s*["']?([^"',\s)]+)/, 1]
      end

      # `turbo_stream_from :notifications`, `"notifications"`, `@room`,
      # `current_user, :notifications`, `"post_#{@post.id}"`: a symbol colon
      # and quotes go, an interpolation reads as its last call (`post_{id}`).
      def subscription_stream(line)
        match = line.match(/turbo_stream_from\s+(.+?)(?:\s*%>|\s*$|\s*do\b)/)
        return "(dynamic)" unless match

        args = match[1].strip
        return normalize_interpolation(args) if args.include?("#")

        top_level_arguments(args).map { |arg| bare_stream_name(arg) }.join(", ")
      end

      # Only a whole symbol loses its colon and only a whole string its quotes;
      # an array or a call keeps every character it was written with.
      def bare_stream_name(arg)
        return arg.delete_prefix(":") if arg.match?(/\A:[A-Za-z_]\w*[?!]?\z/)
        return arg[1..-2] if arg.match?(/\A"[^"]*"\z/) || arg.match?(/\A'[^']*'\z/)

        arg
      end

      def normalize_interpolation(text)
        text.gsub(/["']/, "").gsub(/#\{(.+?)\}/) { "{#{Regexp.last_match(1).strip.split(".").last}}" }
      end

      def extract_turbo_stream_templates
        return [] unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, "**/*.turbo_stream.erb")).filter_map do |path|
          path.sub("#{views_dir}/", "")
        end.sort
      end

      def extract_stream_actions
        actions = Hash.new(0)
        return actions unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, "**", "*.turbo_stream.erb")).each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          content.scan(/turbo_stream\.(\w+)/).each { |action| actions[action[0]] += 1 }
          content.scan(/<turbo-stream\s+action=["'](\w+)["']/).each { |action| actions[action[0]] += 1 }
        end
        actions
      rescue => e
        $stderr.puts "[rails-ai-context] extract_stream_actions failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # One parse per file: a model file feeds both lists. Concerns stay in,
      # and a concern's macro is reported under the concern's own name.
      # `broadcast_*_to` calls sit inside callbacks, lambdas and method
      # bodies, so they are found by name wherever they appear.
      def scan_broadcasts
        models = []
        explicit = []
        BROADCAST_KINDS.each do |kind|
          SourceScan.each(root, kind: kind, skip_concerns: false) do |record|
            walked = walk_broadcasts(record.source)
            models.concat(model_entries(record, walked[:macros])) if kind == "app/models"
            explicit.concat(explicit_entries(record, walked[:calls]))
          end
        end

        { models: models.sort_by { |b| [ b[:model], b[:line] ] }, explicit: explicit }
      rescue => e
        $stderr.puts "[rails-ai-context] scan_broadcasts failed: #{e.message}" if ENV["DEBUG"]
        { models: [], explicit: [] }
      end

      def model_entries(record, hits)
        owner = nil
        hits.filter_map do |hit|
          next unless hit[:receiver].nil?

          owner ||= owner_name(record)
          { model: owner, macro: hit[:name], stream: macro_stream(hit), file: record.file, line: hit[:line], snippet: hit[:snippet] }
        end
      end

      def explicit_entries(record, hits)
        hits.map do |hit|
          {
            method: hit[:name],
            stream: call_stream(hit[:arguments].first),
            target: hit[:options][:target]&.to_s,
            partial: hit[:options][:partial]&.to_s,
            file: record.file,
            line: hit[:line],
            snippet: hit[:snippet]
          }
        end
      end

      # app/models/concerns is an autoload root, so its path name carries no
      # `Concerns::` segment.
      def owner_name(record)
        DeclaredConstant.resolve(record.source, record.path_name.delete_prefix("Concerns::"))
      end

      def walk_broadcasts(source)
        SourceIntrospector.walk_source(source, {
          macros: -> { Listeners::MethodCallListener.new(names: MODEL_BROADCAST_MACROS) },
          calls: -> { Listeners::MethodCallListener.new(pattern: BROADCAST_CALL) }
        })
      end

      # The bare macros stream to the model's own plural; the `_to` forms
      # name a stream only when the first argument is a symbol, a string or
      # a bare identifier. A lambda is a stream this reading cannot name.
      def macro_stream(hit)
        case hit[:name]
        when "broadcasts" then "self (model plural)"
        when "broadcasts_refreshes" then "self (model plural, refreshes)"
        else
          first = hit[:arguments].first
          first.to_s if first.is_a?(Symbol) || first.to_s.match?(/\A\w+\z/)
        end
      end

      # `"post_#{post.id}"` reads as `post_{id}`; a symbol, a string or a bare
      # identifier as itself; anything else is dynamic.
      def call_stream(argument)
        text = argument.to_s
        return normalize_interpolation(text) if text.match?(/\A["'].*#\{/)
        return text if argument.is_a?(Symbol) || text.match?(/\A\w+\z/)

        "(dynamic)"
      end

      def detect_morph_meta
        layouts_dir = File.join(root, "app/views/layouts")
        return false unless Dir.exist?(layouts_dir)

        Dir.glob(File.join(layouts_dir, "*.{erb,haml,slim}")).any? do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          content.include?('name="turbo-refresh-method"') && content.include?('content="morph"')
        end
      rescue => e
        $stderr.puts "[rails-ai-context] detect_morph_meta failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def extract_permanent_elements
        return [] unless Dir.exist?(views_dir)

        elements = []
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          relative = path.sub("#{views_dir}/", "")

          content.scan(/<[^>]*data-turbo-permanent[^>]*>/i).each do |tag|
            id = tag.match(/id=["']([^"']+)["']/)&.send(:[], 1)
            elements << { file: relative, id: id }
          end
        end

        # Also scan layouts
        layouts_dir = File.join(root, "app/views/layouts")
        if Dir.exist?(layouts_dir)
          Dir.glob(File.join(layouts_dir, "*.{erb,haml,slim}")).each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            relative = "layouts/#{File.basename(path)}"

            content.scan(/<[^>]*data-turbo-permanent[^>]*>/i).each do |tag|
              id = tag.match(/id=["']([^"']+)["']/)&.send(:[], 1)
              elements << { file: relative, id: id }
            end
          end
        end

        elements.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_permanent_elements failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_turbo_drive_settings
        return { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 } unless Dir.exist?(views_dir)

        counts = { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 }
        all_dirs = [ views_dir ]
        layouts_dir = File.join(root, "app/views/layouts")
        all_dirs << layouts_dir if Dir.exist?(layouts_dir)

        all_dirs.each do |dir|
          Dir.glob(File.join(dir, "**/*.{erb,haml,slim}")).each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            counts[:"data-turbo-false"] += content.scan(/data-turbo=["']false["']/).size
            counts[:"data-turbo-action"] += content.scan(/data-turbo-action=["'][^"']*["']/).size
            # Also count Rails data hash syntax: data: { turbo_action: ... }
            counts[:"data-turbo-action"] += content.scan(/turbo_action:\s*["'][^"']*["']/).size
            counts[:"data-turbo-preload"] += content.scan(/data-turbo-preload/).size
          end
        end

        counts
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_drive_settings failed: #{e.message}" if ENV["DEBUG"]
        { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 }
      end

      # Concerns stay in: a native include or a turbo_stream response can
      # live in one.
      def controller_sources
        SourceScan.each(root, kind: "app/controllers", skip_concerns: false)
      end

      # One walk over app/controllers feeding every collector that needs it,
      # the way scan_broadcasts already reads app/models once. Each collector
      # scanning for itself read and parsed the same files four times.
      def scan_controllers
        @scan_controllers ||= begin
          include_found = false
          helpers = []
          navigation = []
          responses = []

          each_controller_record do |record|
            source = record.source
            collect { include_found ||= native_navigation_included?(source) }
            collect { helpers << record.file if source.match?(NATIVE_HELPER) }
            collect { source.scan(NATIVE_NAVIGATION) { |m| navigation << { file: record.file, method: m } } }
            collect { responses.concat(stream_responses_in(record)) }
          end

          {
            native_include: include_found,
            native_helpers: helpers.sort,
            native_navigation: navigation.sort_by { |r| [ r[:file], r[:method] ] },
            turbo_stream_responses: responses.uniq.sort_by { |r| [ r[:controller], r[:action] ] }
          }
        end
      end

      # One collector raising costs its own list for that file only, and the
      # memo is assigned either way so a failure is not re-walked on every
      # later call.
      def collect
        yield
      rescue => e
        $stderr.puts "[rails-ai-context] scan_controllers collector failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def each_controller_record(&block)
        controller_sources.each(&block)
      rescue => e
        $stderr.puts "[rails-ai-context] scan_controllers failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def native_navigation_included?(source)
        walked = SourceIntrospector.walk_source(source, {
          includes: -> { Listeners::GenericMacroListener.new(:include) }
        })
        Array(walked[:includes]).any? { |hit| hit[:values].include?("Turbo::Native::Navigation") }
      end

      # Tying a `format.turbo_stream` call to the action it sits in needs
      # block scope, which the listeners do not track. Line scanning stays.
      def stream_responses_in(record)
        controller_name = DeclaredConstant.resolve(record.source, record.path_name)

        found = []
        current_action = nil
        record.source.each_line do |line|
          if (match = line.match(/^\s*def\s+(\w+)/))
            current_action = match[1]
          end

          if current_action && line.match?(/format\.turbo_stream|respond_to\s*.*turbo_stream/)
            found << { controller: controller_name, action: current_action }
          end
        end
        found
      end

      def detect_turbo_native
        scanned = scan_controllers
        {
          detected: scanned[:native_include],
          native_helpers: scanned[:native_helpers],
          native_navigation: scanned[:native_navigation],
          native_conditionals: detect_native_conditionals
        }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_turbo_native failed: #{e.message}" if ENV["DEBUG"]
        { detected: false, native_helpers: [], native_navigation: [], native_conditionals: 0 }
      end

      def detect_native_conditionals
        return 0 unless Dir.exist?(views_dir)

        count = 0
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          count += content.scan(/turbo_native_app\?|hotwire_native_app\?/).size
        end

        count
      rescue => e
        $stderr.puts "[rails-ai-context] detect_native_conditionals failed: #{e.message}" if ENV["DEBUG"]
        0
      end

      def extract_turbo_stream_responses
        scan_controllers[:turbo_stream_responses]
      end
    end
  end
end
