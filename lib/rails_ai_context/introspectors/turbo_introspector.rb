# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans for Hotwire/Turbo usage: frames, streams, model broadcasts.
    class TurboIntrospector < Base
      extend StaticTier
      static_tier :files_only

      MODEL_BROADCAST_MACROS = %w[broadcasts broadcasts_to broadcasts_refreshes broadcasts_refreshes_to].freeze
      BROADCAST_CALL = /\Abroadcast_\w+_to\z/
      BROADCAST_KINDS = %w[app/controllers app/services app/jobs app/workers app/channels].freeze

      # A mention of these helpers anywhere in a controller is the signal,
      # whether called, referenced or guarded. Vocabulary, not structure, so
      # regex rather than a listener.
      NATIVE_HELPER = /turbo_native_app\?|hotwire_native_app\?/
      NATIVE_NAVIGATION = Regexp.union(%w[
        recede_or_redirect_to resume_or_redirect_to refresh_or_redirect_to
        recede_or_redirect_back_or_to resume_or_redirect_back_or_to refresh_or_redirect_back_or_to
      ])

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
      end

      private

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
        RailsAiContext.debug_fail(e, [], label: "extract_turbo_frames")
      end

      def extract_stream_subscriptions
        subscriptions = []
        each_view_line do |file, line, line_num|
          next unless line.include?("turbo_stream_from")

          subscriptions << { stream: subscription_stream(line), file: file, line: line_num, snippet: line.strip }
        end
        subscriptions
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_stream_subscriptions")
      end

      # One read of every views root per run, in path order, for every views collector.
      # ponytail: holds every markup view's text for the call; stream per file if memory matters.
      def view_files
        return @view_files if defined?(@view_files)

        # Memoized only once complete: a raise part way through would leave later collectors
        # reading a truncated list.
        files = []
        RailsAiContext::ViewFile.each(root, RailsAiContext::ViewFile::MARKUP_GLOB).each do |path, relative|
          real = File.realpath(path)
          next unless SafePath.contained?(real, File.realpath(views_root_of(path)))

          content = RailsAiContext::SafeFile.read(real) or next
          files << { file: path.sub("#{root}/", ""), relative: relative, content: content }
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          next
        end
        @view_files = files
      end

      # The views root a path was found under, for the containment check that
      # keeps a symlink escaping the tree out of the answer.
      def views_root_of(path)
        RailsAiContext::ViewFile.root_for(path, PathResolver.view_dirs(root)) || views_dir
      end

      # Views are not Ruby, so they are read line by line. Files are yielded
      # in path order with their root-relative name and 1-based line.
      def each_view_line
        view_files.each do |entry|
          entry[:content].each_line.with_index(1) { |line, line_num| yield entry[:file], line, line_num }
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
        args = [ +"" ]
        RailsAiContext::Brackets.each_top_level(text, comments: :ruby) do |piece, kind|
          next if kind == :comment

          kind == :char && piece == "," ? args << +"" : args.last << piece
        end
        args.map(&:strip).reject(&:empty?)
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
        stream_templates.map { |_path, relative| relative }.sort
      end

      def stream_templates
        RailsAiContext::ViewFile.each(root, "**/*.turbo_stream.erb")
      end

      def extract_stream_actions
        actions = Hash.new(0)
        stream_templates.each do |path, _relative|
          content = RailsAiContext::SafeFile.read(path) or next
          content.scan(/turbo_stream\.(\w+)/).each { |action| actions[action[0]] += 1 }
          content.scan(/<turbo-stream\s+action=["'](\w+)["']/).each { |action| actions[action[0]] += 1 }
        end
        actions
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "extract_stream_actions")
      end

      # One parse per file: a model file feeds both lists. Concerns stay in,
      # and a concern's macro is reported under the concern's own name.
      # `broadcast_*_to` calls sit inside callbacks, lambdas and method
      # bodies, so they are found by name wherever they appear.
      def scan_broadcasts
        models = []
        explicit = []
        seen = Set.new
        # A model outside app/models also sits under another kind's directory.
        [ :models, *BROADCAST_KINDS ].each do |kind|
          records = kind == :models ? model_sources(skip_concerns: false) : SourceScan.each(root, kind: kind, skip_concerns: false)
          records.each do |record|
            next unless seen.add?(record.path)

            walked = walk_broadcasts(record.source)
            models.concat(model_entries(record, walked[:macros])) if kind == :models
            explicit.concat(explicit_entries(record, walked[:calls]))
          end
        end

        { models: models.sort_by { |b| [ b[:model], b[:line] ] }, explicit: explicit }
      rescue => e
        RailsAiContext.debug_fail(e, { models: [], explicit: [] }, label: "scan_broadcasts")
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

      # A concerns directory is an autoload root, so its path name carries no
      # `Concerns::` segment; every scan here names a class through this.
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
        RailsAiContext::ViewFile.each(root, "layouts/*.{erb,haml,slim}").any? do |path, _relative|
          content = RailsAiContext::SafeFile.read(path) or next
          content.include?('name="turbo-refresh-method"') && content.include?('content="morph"')
        end
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "detect_morph_meta")
      end

      def extract_permanent_elements
        return [] unless Dir.exist?(views_dir)

        elements = []
        view_files.each do |entry|
          entry[:content].scan(/<[^>]*data-turbo-permanent[^>]*>/i).each do |tag|
            id = tag.match(/id=["']([^"']+)["']/)&.send(:[], 1)
            elements << { file: entry[:relative], id: id }
          end
        end

        elements.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_permanent_elements")
      end

      def extract_turbo_drive_settings
        return { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 } unless Dir.exist?(views_dir)

        counts = { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 }
        view_files.each do |entry|
          content = entry[:content]
          counts[:"data-turbo-false"] += content.scan(ViewTemplateIntrospector.data_attr("data-turbo")).count { |m| m[0] == "false" }
          counts[:"data-turbo-false"] += content.scan(/data-turbo["']?\s*(?:=>|=|:)\s*false\b/).size
          counts[:"data-turbo-action"] += content.scan(ViewTemplateIntrospector.data_attr("data-turbo-action")).size
          # Also count Rails data hash syntax: data: { turbo_action: ... }
          counts[:"data-turbo-action"] += content.scan(/turbo_action:\s*["'][^"']*["']/).size
          counts[:"data-turbo-preload"] += content.scan(/data-turbo-preload/).size
        end

        counts
      rescue => e
        RailsAiContext.debug_fail(e, { "data-turbo-false": 0, "data-turbo-action": 0, "data-turbo-preload": 0 }, label: "extract_turbo_drive_settings")
      end

      # One walk over app/controllers feeding every collector that needs it,
      # the way scan_broadcasts already reads app/models once. Each collector
      # scanning for itself read and parsed the same files four times. The
      # memo is assigned either way, so a failure is not re-walked on every
      # later call.
      def scan_controllers
        @scan_controllers ||= build_controller_scan
      end

      def build_controller_scan
        include_found = false
        helpers = []
        navigation = []
        responses = []

        # Concerns stay in: a native include or turbo_stream response can live in one.
        # A raise mid-walk keeps the entries already collected.
        guarded do
          SourceScan.each(root, kind: "app/controllers", skip_concerns: false) do |record|
            source = record.source
            guarded { include_found ||= native_navigation_included?(source) }
            guarded { helpers << record.file if source.match?(NATIVE_HELPER) }
            guarded { source.scan(NATIVE_NAVIGATION) { |m| navigation << { file: record.file, method: m } } }
            guarded { responses.concat(stream_responses_in(record)) }
          end
        end

        # Each list is ordered under its own collector's rescue: an entry the
        # comparison cannot order costs that list its order, not the section.
        guarded { helpers.sort! }
        guarded { navigation.sort_by! { |r| [ r[:file], r[:method] ] } }
        guarded { responses.uniq! }
        guarded { responses.sort_by! { |r| [ r[:controller], r[:action] ] } }

        {
          native_include: include_found,
          native_helpers: helpers,
          native_navigation: navigation,
          turbo_stream_responses: responses
        }
      rescue => e
        RailsAiContext.debug_fail(e, { native_include: false, native_helpers: [], native_navigation: [], turbo_stream_responses: [] }, label: "scan_controllers")
      end

      # One collector raising costs its own list, not the section.
      def guarded
        yield
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "scan_controllers collector")
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
        controller_name = owner_name(record)

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
        RailsAiContext.debug_fail(e, { detected: false, native_helpers: [], native_navigation: [], native_conditionals: 0 }, label: "detect_turbo_native")
      end

      def detect_native_conditionals
        return 0 unless Dir.exist?(views_dir)

        count = 0
        view_files.each do |entry|
          count += entry[:content].scan(/turbo_native_app\?|hotwire_native_app\?/).size
        end

        count
      rescue => e
        RailsAiContext.debug_fail(e, 0, label: "detect_native_conditionals")
      end

      def extract_turbo_stream_responses
        scan_controllers[:turbo_stream_responses]
      end
    end
  end
end
