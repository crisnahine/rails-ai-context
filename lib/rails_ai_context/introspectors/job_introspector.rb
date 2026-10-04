# frozen_string_literal: true

require "yaml"

module RailsAiContext
  module Introspectors
    # Discovers ActiveJob jobs, mailers, Action Cable channels, and the
    # Sidekiq workers that are none of those: a class that includes
    # Sidekiq::Job or Sidekiq::Worker is not an ActiveJob descendant and does
    # not live in app/jobs/, so both job passes miss it. On an app that runs
    # its background work that way, workers are the whole picture.
    class JobIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      CHANNEL_MACROS = %i[identified_by stream_from stream_for periodically].freeze

      # Both kinds of job live in all three; which one a class is comes from
      # the class, never from the directory.
      JOB_DIRS = %w[app/jobs app/workers app/sidekiq].freeze
      ACTIVE_JOB_BASES = %w[ActiveJob::Base ApplicationJob ActionMailer::MailDeliveryJob].freeze
      JOB_MACROS = %i[
        queue_as retry_on discard_on
        sidekiq_options sidekiq_throttle include
        before_enqueue after_enqueue before_perform after_perform
        around_perform around_enqueue
      ].freeze

      # @return [Hash] async workers, mailers, and channels
      def call
        jobs = merge_with_source(extract_jobs, extract_jobs_from_source)

        {
          jobs: jobs,
          workers: extract_workers,
          job_bases: job_bases,
          enqueue_helpers: enqueue_helpers,
          mailers: booted_mailers[:mailers],
          mailer_bases: booted_mailers[:bases],
          channels: extract_channels,
          recurring_jobs: extract_solid_queue_recurring,
          sidekiq_config: extract_sidekiq_config
        }
      end

      # Mailers and channels are ordinary classes in ordinary directories, so
      # the answer is the same with or without a booted app. Only the way in
      # differs: descendants when Rails is up, the AST when it is not.
      def static_call
        {
          jobs: extract_jobs_from_source,
          workers: extract_workers,
          job_bases: job_bases,
          enqueue_helpers: enqueue_helpers,
          mailers: source_mailers[:mailers],
          mailer_bases: source_mailers[:bases],
          channels: extract_channels_from_source,
          recurring_jobs: extract_solid_queue_recurring,
          sidekiq_config: extract_sidekiq_config
        }
      end

      private

      def extract_jobs
        return [] unless defined?(ActiveJob::Base)

        JOB_DIRS.each { |kind| EagerLoad.dir(app.root, kind: kind) }

        ActiveJob::Base.descendants.filter_map do |job|
          next if job.name.nil? || job.name == "ApplicationJob" ||
                  job.name.start_with?("ActionMailer", "ActiveStorage::", "ActionMailbox::", "Turbo::", "Sentry::")
          next unless app_defined?(job)
          if SuperclassChain.abstract_base?(job.name, inherited: job.descendants.any?)
            reflected_bases << { name: job.name, file: source_file_for(job) }
            next
          end

          queue = job.queue_name
          # The default is a lambda; another Proc is a queue_as block, and a
          # Proc argument is stored as its inspect string, with the line that set it.
          if queue.equal?(ActiveJob::Base.queue_name)
            queue = job.queue_name_from_part(nil)
          elsif queue.is_a?(Proc)
            queue = labelled(COMPUTED_QUEUE, queue.source_location && block_at(*queue.source_location))
          elsif queue.to_s.include?("#<Proc:")
            location = queue.match(/#<Proc:0x\h+ (.+):(\d+)(?: \(lambda\))?>/)
            queue = labelled(PROC_QUEUE, location && proc_at(location[1], location[2].to_i))
          end

          {
            name: job.name,
            file: source_file_for(job),
            queue: queue.to_s,
            priority: job.priority
          }.compact
        end.sort_by { |j| j[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_jobs")
      end

      # The bases the listings leave out, each with the file it was read from, so a base
      # asked for by name is answered from its source.
      def job_bases
        from_source = job_candidates.filter_map { |name, candidate| base_record(name, candidate) if base?(name) }
        known = from_source.map { |base| base[:name] }
        (from_source + reflected_bases.reject { |base| known.include?(base[:name]) }).sort_by { |base| base[:name] }
      end

      # What a base declares is what every job inheriting it runs with, such as the queue
      # all its workers use.
      def base_record(name, candidate)
        macros = candidate.ast[:macros]
        declares = class_body(macros, candidate.source).select { |m| JOB_BASE_DECLARATIONS.include?(m[:macro]) }
                         .sort_by { |m| m[:offset] }.map { |m| written(candidate.source, m) }
        heirs = job_candidates.keys.select { |other| other != name && chain_of(other).include?(name) }
        { name: name, file: candidate.file, queue: inherited_queue(name),
          options: inherited_options(name).presence, retries: RetryPolicy.entries(macros).presence,
          declares: declares.presence, inherited_by: heirs.sort.presence }.compact
      end

      # What a base declares beyond its queue, options and retries: the mixins, the
      # throttle and the callbacks every job below it runs with.
      JOB_BASE_DECLARATIONS = %i[
        include sidekiq_throttle before_enqueue after_enqueue before_perform after_perform
        around_perform around_enqueue
      ].freeze

      # Sidekiq hands `sidekiq_options` to a subclass and ActiveJob hands it `queue_as`,
      # so both are read down the app's chain, the nearest class that sets a key winning.
      def inherited_options(name)
        chain_of(name).reverse.reduce({}) { |options, link| options.merge(sidekiq_options(job_candidates[link].ast[:macros])) }
      end

      # Which class up the chain set each option this class did not set itself.
      def option_sources(name)
        chain_of(name).drop(1).each_with_object({}) do |link, sources|
          sidekiq_options(job_candidates[link].ast[:macros]).each_key do |key|
            sources[key] ||= link unless sidekiq_options(job_candidates[name].ast[:macros]).key?(key)
          end
        end
      end

      def inherited_queue(name)
        chain_of(name).lazy.filter_map { |link| queue_as(job_candidates[link].ast) }.first
      end

      def labelled(label, source)
        source ? "#{label}: `#{source}`" : label
      end

      def block_at(file, line)
        queue_as_walk(file)&.dig(:macros)&.find { |m| m[:macro] == :queue_as && m[:location] == line && m[:block] }&.dig(:block)
      end

      # Only one Proc literal on the line says which one it was.
      def proc_at(file, line)
        found = queue_as_walk(file)&.dig(:procs)&.select { |literal| literal[:line] == line } || []
        found.first[:source] if found.one?
      end

      # Only the app's own files are read; a job file reuses the walk that found it.
      def queue_as_walk(file)
        @queue_as_walks ||= {}
        @queue_as_walks.fetch(file) do
          @queue_as_walks[file] = begin
            real = File.realpath(file)
            root = app.root.to_s
            if SourceScan.under_root?(file, real, root, app_root_real)
              relative = SourceScan.relative_file(file, real, root, app_root_real)
              job_candidates.values.find { |candidate| candidate.file == relative }&.ast ||
                (source = SafeFile.read(file)) && SourceIntrospector.walk_source(source, QUEUE_AS_LISTENERS)
            end
          rescue SystemCallError
            nil
          end
        end
      end

      # This class and its ancestors among the candidates, nearest first.
      def chain_of(name)
        chain = []
        while name && job_candidates.key?(name) && !chain.include?(name)
          chain << name
          name = superclass_of(name)
        end
        chain
      end

      COMPUTED_QUEUE = "computed by a block"
      PROC_QUEUE = "queue_as given a Proc: ActiveJob does not call it, so the queue is named after the Proc's text"
      PROC_LITERAL = /\A(?:->|(?:lambda|proc|Proc\.new)(?![\w.]))/

      QUEUE_AS_LISTENERS = {
        macros: -> { Listeners::GenericMacroListener.new(*JOB_MACROS, block_source: [ :queue_as ]) },
        procs:  Listeners::ProcLiteralListener
      }.freeze

      # A literal queue by name; one picked at enqueue time by the source that
      # picks it, the way other computed values read.
      def queue_as(ast)
        hit = ast[:macros].find { |m| m[:macro] == :queue_as } or return nil
        return hit[:args].first.to_s if hit[:args].any?
        return labelled(COMPUTED_QUEUE, hit[:block]) if hit[:block]

        source = hit[:values].first.to_s.gsub(/\s+/, " ").strip
        return COMPUTED_QUEUE if source.empty?

        assigned = Array(ast[:procs]).find { |literal| literal[:constant] == source }
        return labelled(PROC_QUEUE, assigned[:source]) if assigned

        source.match?(PROC_LITERAL) ? labelled(PROC_QUEUE, source) : "`#{source}` (computed)"
      end

      def sidekiq_options(macros)
        hit = macros.find { |m| m[:macro] == :sidekiq_options }
        hit ? (hit[:option_values] || {}).transform_keys(&:to_s) : {}
      end

      # Named and subclassed like a base, and a job by its own chain: a subclassed class
      # that reaches neither ActiveJob nor a Sidekiq mixin is no job and no job base.
      def base?(name)
        SuperclassChain.abstract_base?(name, inherited: inherited_names.include?(name)) &&
          (worker?(name) || active_job?(name))
      end

      def reflected_bases
        @reflected_bases ||= []
      end

      ENQUEUE_HELPERS = %w[enqueue enqueue_in enqueue_at].freeze

      # An app that enqueues through its own helper (`Jobs.enqueue(:process_post)`) names a
      # job by a symbol; the helper's def says whose namespace it is and which argument.
      def enqueue_helpers
        methods = job_candidates.values.flat_map { |candidate| candidate.ast[:methods] }
        SourceScan.each(app.root, kind: "lib") do |record|
          methods.concat(ActionResolver.methods_in(record.source)) if record.source.include?("def self.enqueue")
        end
        methods.filter_map { |method|
          next unless method[:scope] == :class && ENQUEUE_HELPERS.include?(method[:name])

          owner = ActionResolver.owner_name(method).presence or next
          params = Array(method[:params]).map { |param| param[:name].to_s }
          { owner: owner, method: method[:name], job_arg: params.index { |name| name.match?(/job|klass|class/) } || 0 }
        }.uniq
      end

      # Reflection answers the queue; the source answers what reflection cannot
      # see: retries and signatures, and the Resque jobs, POROs and jobs in roots
      # Zeitwerk never loads. On a name both answer, reflection wins.
      def merge_with_source(reflected, from_source)
        return from_source if reflected.empty?

        sourced = from_source.index_by { |job| job[:name] }
        merged = reflected.map { |job| (sourced.delete(job[:name]) || {}).except(:unknown_base).merge(job) }
        bases = reflected_bases.map { |base| base[:name] }
        (merged + sourced.values.reject { |job| bases.include?(job[:name]) }).sort_by { |job| job[:name] }
      end

      # `descendants` is every ActiveJob subclass in the process, and the name
      # prefixes above only cover the framework's own - a job from any other gem
      # was counted as the app's. Where the class is defined answers it for gems
      # the list has never heard of. A class with no source location stays:
      # dropping one would understate what the app runs.
      def app_defined?(klass)
        location = Object.const_source_location(klass.name)&.first
        return true unless location

        SourceScan.under_root?(location, File.realpath(location), app.root.to_s, app_root_real)
      rescue NameError, ArgumentError, TypeError, SystemCallError
        true
      end

      def app_root_real
        @app_root_real ||= File.realpath(app.root.to_s)
      rescue SystemCallError
        @app_root_real = app.root.to_s
      end

      def extract_jobs_from_source
        job_candidates.filter_map do |name, candidate|
          next if name == "ApplicationJob" || worker?(name) || base?(name)

          ast = candidate.ast
          unknown_base = !active_job?(name)
          next if unknown_base && !performs?(ActionResolver.own_methods(ast[:methods], candidate.declared))

          queue = inherited_queue(name)

          perform_method = ast[:methods].find { |m| m[:name] == "perform" && m[:scope] == :instance }
          perform_signature = ActionResolver.parameter_list(perform_method) if perform_method && perform_method[:params]&.any?

          # Extract job callbacks
          callback_names = %i[before_enqueue after_enqueue before_perform after_perform around_perform around_enqueue]
          callbacks = ast[:macros]
            .select { |m| callback_names.include?(m[:macro]) }
            .map { |m| m[:macro].to_s }
            .uniq

          retries = RetryPolicy.entries(ast[:macros])

          job = { name: name, file: candidate.file }
          job[:unknown_base] = true if unknown_base
          job[:queue] = queue if queue
          job[:retries] = retries if retries.any?
          job[:perform_signature] = perform_signature if perform_signature
          job[:callbacks] = callbacks if callbacks.any?
          job
        end.sort_by { |j| j[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_jobs_from_source")
      end

      # Sidekiq workers, read from source in both tiers: the class is not an
      # ActiveJob descendant, so reflection has no list to walk.
      WORKER_MIXINS = %w[Sidekiq::Job Sidekiq::Worker Sidekiq::IterableJob].freeze

      def extract_workers
        job_candidates.filter_map do |name, candidate|
          next unless worker?(name)
          next if base?(name)

          ast = candidate.ast
          throttle = ast[:macros].find { |m| m[:macro] == :sidekiq_throttle }
          entry = ActionResolver.entry_point(ast[:methods])
          # Everything a listing prints about a worker rides the record: the
          # tool holds the name and no source.
          retries = RetryPolicy.entries(ast[:macros])
          calls = SourceCalls.calls_from(ast[:calls], own: name)

          {
            name: name,
            file: candidate.file,
            line_count: candidate.source.lines.size,
            options: inherited_options(name),
            inherited_from: option_sources(name).presence,
            throttle: throttle && throttle_summary(throttle),
            entry_point: entry && entry[:name] == "execute" ? "execute" : nil,
            perform_signature: entry && entry[:params]&.any? ? ActionResolver.parameter_list(entry) : nil,
            retries: retries.any? ? retries : nil,
            calls: calls.any? ? calls : nil
          }.compact
        end.sort_by { |w| w[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_workers")
      end

      # One class file. `declares` carries every constant in it, so a subclass
      # elsewhere can find its base here.
      Candidate = Data.define(:file, :source, :declared, :declares, :superclass, :ast)

      # Every class in every job directory, one walk each. The kind of job waits for the
      # whole map: the mixin or ActiveJob ancestry is often on a base in another file.
      def job_candidates
        @job_candidates ||= JOB_DIRS.each_with_object({}) do |kind, found|
          SourceScan.each(app.root, kind: kind) do |record|
            declarations = DeclaredConstant.declarations(record.source)
            next if declarations.empty?

            declaration = DeclaredConstant.declaration_for(declarations, record.path_name) || declarations.first
            name = job_name(declaration, record)
            next if found.key?(name)
            found[name] = Candidate.new(
              file: record.file,
              source: record.source,
              declared: declaration.name,
              declares: declarations.map(&:name),
              superclass: declaration.superclass,
              ast: SourceIntrospector.walk_source(record.source, QUEUE_AS_LISTENERS.merge(
                methods: Listeners::MethodsListener,
                calls:   SourceCalls.listener
              ))
            )
          end
        end
      end

      # A declaration that writes its own namespace names the job (the path may camelize
      # to Regular::Foo where the app says Jobs::Foo); otherwise the path carries it.
      def job_name(declaration, record)
        return declaration.name if declaration&.name&.include?("::")

        DeclaredConstant.resolve(record.source, record.path_name)
      end

      # Every name a candidate answers to, mapped to its key: a subclass's base is often
      # a second class in another file, not a file of its own.
      def candidate_names
        @candidate_names ||= job_candidates.each_with_object({}) do |(name, candidate), index|
          index[name] ||= name
          candidate.declares.each { |declared| index[declared] ||= name }
        end
      end

      # The candidate a class inherits from, keyed the way the map keys it.
      def superclass_of(name)
        candidate = job_candidates[name] or return nil

        SuperclassChain.resolve_in_scope(candidate.declared, candidate.superclass) do |qualified|
          candidate_names[qualified]
        end
      end

      # Whether the chain reaches ActiveJob. The job directories answer first, since a base
      # there is often namespace-relative; anything else goes through the autoload roots.
      def active_job?(name, seen = [])
        return false if seen.include?(name)

        candidate = job_candidates[name] or return false
        parent = candidate.superclass or return false
        return true if ACTIVE_JOB_BASES.include?(parent)

        resolved = superclass_of(name)
        return active_job?(resolved, seen + [ name ]) if resolved

        @superclass_lookup ||= SuperclassChain.lookup_for(app.root)
        SuperclassChain.to(candidate.source, bases: ACTIVE_JOB_BASES,
                           lookup: @superclass_lookup, only: candidate.declared).any?
      end


      def inherited_names
        @inherited_names ||= job_candidates.keys.filter_map { |name| superclass_of(name) }.uniq
      end

      # A Resque job is a bare class with a class-level perform, a PORO an instance one.
      # The class's own, not the file's: an error class beside a job has none.
      def performs?(methods)
        methods.any? { |m| m[:name] == "perform" }
      end

      # A throttle decides how fast a worker runs whatever the queue and the
      # pool allow, so a bracket carrying queue and retry without it reads as
      # the worker's constraints while leaving out the binding one. Rendered
      # from the source text: the limits are often expressions (1.minute),
      # which have no literal value to read.
      def throttle_summary(macro)
        nodes = macro[:option_nodes] || {}
        return nil if nodes.empty?

        nodes.filter_map { |key, node|
          next unless node.respond_to?(:slice)
          "#{key} #{NodeSource.text(node).gsub(/\s+/, " ")}"
        }.join(", ").presence
      end

      def worker?(name, seen = [])
        return false if seen.include?(name)

        candidate = job_candidates[name] or return false
        return true if candidate.ast[:macros].any? { |m|
          m[:macro] == :include && m[:values].flatten.map(&:to_s).any? { |v| WORKER_MIXINS.include?(v) }
        }

        parent = superclass_of(name) or return false
        worker?(parent, seen + [ name ])
      end

      def extract_solid_queue_recurring
        paths = [
          File.join(app.root, "config", "recurring.yml"),
          File.join(app.root, "config", "solid_queue.yml")
        ]
        path = paths.find { |p| File.exist?(p) }
        return [] unless path

        content = RailsAiContext::SafeFile.read(path)
        return [] unless content
        jobs = []
        content.scan(/(\w+):\s*\n\s+class:\s*(\w+).*?(?:schedule:\s*["']?([^"'\n]+))?/m) do |name, klass, schedule|
          jobs << { name: name, class: klass, schedule: schedule&.strip }.compact
        end
        jobs
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_solid_queue_recurring")
      end

      # Read as YAML so a path in a comment is no queue. Sidekiq's keys may be symbols or
      # sit under an env section, and a queue may carry a weight (`[critical, 2]`).
      def extract_sidekiq_config
        data = sidekiq_yml or return nil

        config = {}
        concurrency = sidekiq_value(data, "concurrency")
        config[:concurrency] = concurrency.to_i if concurrency
        queues = Array(sidekiq_value(data, "queues"))
          .filter_map { |entry| (entry.is_a?(Array) ? entry.first : entry).to_s.presence }.uniq
        config[:queues] = queues if queues.any?
        config.empty? ? nil : config
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_sidekiq_config")
      end

      def sidekiq_yml
        path = File.join(app.root, "config", "sidekiq.yml")
        return nil unless File.exist?(path)

        content = RailsAiContext::SafeFile.read(path) or return nil
        data = YAML.safe_load(RailsAiContext::ErbSource.without_tags(content),
                              aliases: true, permitted_classes: [ Symbol ])
        data.is_a?(Hash) ? data : nil
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "sidekiq_yml")
      end

      # This environment's section, then the top level, then any other environment: a
      # queue list under `production:` alone is still what the app runs.
      def sidekiq_value(data, key)
        sections = [ data[RailsAiContext.environment_name], data ] + data.values
        sections.filter_map { |section| section[key] || section[key.to_sym] if section.is_a?(Hash) }.first
      end

      # The listing and the bases it leaves out, from one walk.
      def booted_mailers
        @booted_mailers ||= begin
          bases = []
          mailers = extract_mailers(bases)
          { mailers: mailers, bases: bases.uniq { |base| base[:name] }.sort_by { |base| base[:name] } }
        end
      end

      # Reflection names the base and its descendants; what it declares is in
      # its source.
      def booted_mailer_base(mailer)
        file = source_file_for(mailer)
        source = file && SafeFile.read(File.join(app.root.to_s, file))
        heirs = mailer.descendants.filter_map(&:name)
        return { name: mailer.name, file: file, inherited_by: heirs.sort.presence }.compact unless source

        walked = SourceIntrospector.walk_source(source, {
          methods: Listeners::MethodsListener,
          macros: -> { Listeners::GenericMacroListener.new(ACTION_CALLBACKS + MAILER_DECLARATIONS) }
        })
        mailer_base_record(mailer.name, file, source, walked[:macros] || [], walked[:methods] || [], heirs)
      end

      def extract_mailers(bases)
        return [] unless defined?(ActionMailer::Base)

        # In development (config.eager_load = false), mailer files are not
        # loaded until first delivery. Without this, .descendants is empty
        # and mailers are reported as absent.
        EagerLoad.dir(app.root, kind: "app/mailers")
        load_mailers_outside_mailer_dirs

        ActionMailer::Base.descendants.filter_map do |mailer|
          # `descendants` is every mailer in the process, and a gem's is not
          # the app's however it is named.
          next if mailer.name.nil? || !app_defined?(mailer)

          # Reflection with the app-base subtraction: `action_methods` stops
          # subtracting at the framework base, so a public helper on a
          # non-abstract ApplicationMailer would arrive as a deliverable
          # action - the mailer reading of the controller leak.
          actions = ActionResolver.deliverable_actions(
            ActionResolver.reflected_actions(mailer, kind: :mailer), callback_filters(mailer)
          )
          # A base other mailers inherit from is where the helpers they share
          # live. Rails dispatches on those, and no reader sends one.
          if SuperclassChain.abstract_base?(mailer.name, inherited: mailer.descendants.any?)
            bases << booted_mailer_base(mailer)
            next
          end

          entry = {
            name: mailer.name,
            file: source_file_for(mailer),
            actions: actions,
            delivery_method: mailer.delivery_method.to_s
          }.compact
          actions.any? ? entry : entry.merge(no_action_detail(mailer))
        end.sort_by { |m| m[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_mailers")
      end

      # A mailer in app/services or app/models loads only when something names it.
      def load_mailers_outside_mailer_dirs
        return if app.config.eager_load

        EagerLoad.files(mailer_parent_files(SourceScan.paths(app.root, kind: "app/mailers").map(&:file).to_set))
      end

      # The methods this mailer registers as action callbacks. A block filter
      # has no name to match, so only the symbol ones answer.
      def callback_filters(mailer)
        return [] unless mailer.respond_to?(:_process_action_callbacks)

        mailer._process_action_callbacks.map(&:filter).grep(Symbol)
      end

      # Where a mailer with no actions keeps its interface, such as `self.` methods that
      # fan a notification out to many recipients.
      def no_action_detail(mailer)
        { class_actions: callable_class_methods(mailer.singleton_methods(false).map(&:to_s)).sort,
          parent_class: mailer.superclass&.name }.reject { |_k, v| v.nil? || v == [] }
      end

      def callable_class_methods(names)
        names.reject { |n| n.start_with?("_") || MAILER_CLASS_CONFIG.include?(n) }
      end

      # A mailer's actions are its public instance methods, and the AST sees
      # one file at a time. `action_methods` counts the public methods a mailer
      # inherits too, so a public helper on a base class is an action the
      # booted tier reports and this one cannot - the entries are tagged STATIC
      # for that reason.
      # ActionMailer's interceptor and observer hooks. A class or module under
      # app/mailers that implements one is registered with the framework, not
      # delivered by it: reporting OpenProject's Interceptors::DefaultHeaders
      # as a mailer offered `delivering_email` as an email somebody can send.
      # Everything else in that directory stays - a mailer's actions are as
      # often written as modules mixed into one class as they are methods on
      # it, and GitLab keeps 20 such modules holding every notification it
      # sends.
      MAILER_FRAMEWORK_HOOKS = %w[delivering_email previewing_email delivered_email].freeze

      MAILER_BASE = "ActionMailer::Base"

      # ActionMailer configuration a mailer sets on itself; none of it is an interface
      # callers use.
      MAILER_CLASS_CONFIG = %w[
        mailer_name default layout default_url_options controller_path abstract?
        register_interceptor register_observer delivery_method deliveries
      ].freeze

      ACTION_CALLBACKS = %i[
        before_action after_action around_action
        prepend_before_action prepend_after_action prepend_around_action
        append_before_action append_after_action append_around_action
      ].freeze

      def source_mailers
        @source_mailers ||= begin
          scanned = source_classes("app/mailers", macros: ACTION_CALLBACKS + MAILER_DECLARATIONS)
          candidates = scanned.reject { |klass| framework_hook?(klass) } +
                       mailers_outside_mailer_dirs(scanned.map(&:file))
          # A mixin under app/mailers holds a mailer's actions (an Emails::* module); a class
          # is a mailer only when its chain reaches one.
          parent_of = candidates.reject(&:mixin).to_h { |klass| [ klass.name, klass.parent_class ] }
          klasses = candidates.select { |klass| klass.mixin || reaches_mailer?(klass.name, parent_of) }
          bases = abstract_mailer_bases(klasses.reject(&:mixin))
          mailers = klasses.reject { |klass| bases.include?(klass.name) }

          { mailers: mailers.map { |klass| mailer_entry(klass) }.sort_by { |m| m[:name] },
            bases: bases.map do |base|
              klass = klasses.find { |k| k.name == base }
              heirs = mailers.reject(&:mixin).map(&:name).select { |name| inherits_from?(name, base, parent_of) }
              mailer_base_record(base, klass.file, klass.source, klass.macros, klass.methods, heirs)
            end }
        end
      end

      # The hook is often a class method, so the whole declared method list decides. Both
      # passes ask here, or the whole-app pass re-adds what this one dropped.
      def framework_hook?(klass)
        klass.methods.any? { |m| MAILER_FRAMEWORK_HOOKS.include?(m[:name].to_s) }
      end

      # ActionMailer::Base, or a gem parent the app does not define whose name ends in
      # Mailer. An app parent is followed through its autoload roots, cached in `parent_of`.
      def reaches_mailer?(name, parent_of, seen = [])
        parent = parent_of[name]
        return false if parent.nil? || seen.include?(name) || seen.size >= SuperclassChain::MAX_DEPTH
        return true if parent == MAILER_BASE

        app_parent = SuperclassChain.resolve_in_scope(name, parent) { |candidate| candidate if app_class?(candidate, parent_of) }
        return reaches_mailer?(app_parent, parent_of, seen + [ name ]) if app_parent

        parent.split("::").last.end_with?("Mailer")
      end

      # Whether the app defines `name`, recording the parent it names when the
      # source is found on an autoload root.
      def app_class?(name, parent_of)
        return true if parent_of.key?(name)

        source = mailer_lookup.call(name) or return false
        declaration = DeclaredConstant.declaration_named(DeclaredConstant.declarations(source), name)
        return false unless declaration

        parent_of[name] = declaration.superclass
        true
      end

      def mailer_lookup
        @mailer_lookup ||= SuperclassChain.lookup_for(app.root)
      end

      # What a base hands every mailer inheriting it, each written the way the
      # app wrote it, the methods it defines, and who inherits it.
      MAILER_DECLARATIONS = %i[layout helper helper_method include default default_url_options=].freeze

      def mailer_base_record(name, file, source, macros, methods, heirs)
        declares = class_body(macros, source).select { |m| (MAILER_DECLARATIONS + ACTION_CALLBACKS).include?(m[:macro]) }
          .sort_by { |m| m[:offset] }.map { |m| written(source, m) }
        defined = ActionResolver.own_methods(methods, name).select { |m| m[:scope] == :instance }.map { |m| m[:name] }.uniq
        { name: name, file: file, declares: declares.presence, methods: defined.presence,
          inherited_by: heirs.uniq.sort.presence }.compact
      end

      # A macro call as the app wrote it, on one line.
      # Comments come out: a call written across lines with a note on each
      # (`helper :application, # for format_text`) folded them into the call.
      def written(source, macro)
        from = macro[:offset]
        text = source.byteslice(from...macro[:end_offset]).to_s
        comments = AstCache.parse_string(source)&.comments || []
        comments.map(&:location).select { |loc| loc.start_offset >= from && loc.end_offset <= macro[:end_offset] }
                .sort_by(&:start_offset).reverse_each do |loc|
          text = text.byteslice(0, loc.start_offset - from) + text.byteslice((loc.end_offset - from)..).to_s
        end
        text.gsub(/\s+/, " ").gsub(/\(\s+/, "(").sub(/,?\s*\)\z/, ")").strip
      end

      # A declaration is a call in the class body; the same name inside a
      # method - `default[:from]` in a `class << self` reader - is a use.
      def class_body(macros, source)
        root = AstCache.parse_string(source)&.value or return macros
        outside = SourceIntrospector.calls_outside_methods(root, self_receiver: true).values.flatten
                                    .map { |call| call.location.start_offset }
        macros.select { |m| outside.include?(m[:offset]) }
      end

      def inherits_from?(name, base, parent_of, seen = [])
        return false if seen.include?(name) || seen.size >= SuperclassChain::MAX_DEPTH

        parent = SuperclassChain.resolve_in_scope(name, parent_of[name]) { |candidate| candidate if parent_of.key?(candidate) }
        return false unless parent
        return true if parent == base

        inherits_from?(parent, base, parent_of, seen + [ name ])
      end

      # The same question the booted tier asks its descendants, answered off
      # the parent each file names.
      def abstract_mailer_bases(klasses)
        named = klasses.map(&:name).select { |name| SuperclassChain.abstract_base_name?(name) }
        return [] if named.empty?

        inherited = klasses.filter_map do |klass|
          SuperclassChain.resolve_in_scope(klass.name, klass.parent_class) do |candidate|
            candidate if named.include?(candidate)
          end
        end
        named.select { |name| SuperclassChain.abstract_base?(name, inherited: inherited.include?(name)) }.uniq.sort
      end

      # Regex prefilter over every app/ file (a mailer can live in app/models); the AST decides.
      MAILER_PARENT = /^\s*class\s+[\w:]+\s*<\s*(?:[\w:]*Mailer|ActionMailer::Base)\b/
      def mailers_outside_mailer_dirs(scanned_files)
        seen = scanned_files.to_set
        mailer_parent_files(seen).flat_map do |record|
          declarations = DeclaredConstant.declarations(record.source).select(&:superclass)
          next [] if declarations.empty?

          klass = walk_class(record, ACTION_CALLBACKS)
          next [] if klass.nil? || framework_hook?(klass)

          declarations.map { |d| klass.with(name: d.name, parent_class: d.superclass, mixin: false) }
        end
      end

      # Every .rb under app/ that names a mailer parent. The line scan stops at
      # the first match; a file that names none is scanned to its end.
      def mailer_parent_files(seen)
        SourceScan.paths(app.root, kind: "app").filter_map do |record|
          next if seen.include?(record.file) || !names_mailer_parent?(record.path)

          source = SafeFile.read(record.path) or next
          record.with(source: source)
        end
      end

      def names_mailer_parent?(path)
        File.foreach(path) { |line| return true if line.match?(MAILER_PARENT) }
        false
      rescue StandardError
        false
      end

      # What the static tier can say a mailer offers. A class with no action of its own is
      # still a mailer: its actions come from a parent or mixin, or it offers class methods.
      def mailer_entry(klass)
        actions = ActionResolver.deliverable_actions(
          ActionResolver.own_actions(klass.methods, class_name: klass.name),
          klass.macros.select { |m| ACTION_CALLBACKS.include?(m[:macro]) }.flat_map { |m| m[:args] }
        )

        entry = { name: klass.name, file: klass.file, actions: actions,
                  confidence: RailsAiContext::Confidence::STATIC }
        return entry if actions.any?

        class_actions = ActionResolver.own_methods(klass.methods, klass.name)
          .select { |m| m[:scope] == :class && m[:visibility] == :public }
          .map { |m| m[:name] }
        entry[:class_actions] = class_actions.sort if (class_actions = callable_class_methods(class_actions)).any?
        entry[:parent_class] = klass.parent_class if klass.parent_class
        entry
      end

      def extract_channels_from_source
        # ApplicationCable holds the base Channel and Connection, neither of
        # which is a channel of the app's own.
        source_classes("app/channels").filter_map do |klass|
          next if klass.name.start_with?("ApplicationCable::")

          stream_methods = ActionResolver.own_methods(klass.methods, klass.name)
                                         .select { |m| m[:scope] == :instance }
                                         .map { |m| m[:name] }
                                         .select { |m| m.start_with?("stream_") || m == "subscribed" }
          { name: klass.name, file: klass.file, stream_methods: stream_methods,
            confidence: RailsAiContext::Confidence::STATIC }
        end.sort_by { |c| c[:name] }
      end

      # Class name, method list and file for every .rb of a kind, read from
      # the AST. Concerns stay out: Rails adds app/*/concerns as its own
      # autoload root, so what lives there is a mixin, not a mailer or a
      # channel.
      #
      # The name comes from the constant the source declares, with the path as
      # the fallback - see DeclaredConstant for which wins when. The path has
      # to stay in the picture because it is the only thing carrying the
      # namespace when the source does not: `class Channel` in
      # `application_cable/channel.rb` matches no base-class filter and no name
      # the booted app would report.
      def source_classes(kind, macros: [])
        SourceScan.each(app.root, kind: kind).filter_map do |record|
          next if record.source.empty?

          walk_class(record, macros)
        end
      end

      SourceClass = Data.define(:name, :methods, :file, :macros, :parent_class, :mixin, :source)

      # The methods are the file's, since a mailer's actions are often on a mixin; a file
      # declaring a mailer and an interceptor is read as one, and the hook drops both.
      def walk_class(record, macros)
        listeners = { methods: Listeners::MethodsListener }
        listeners[:macros] = -> { Listeners::GenericMacroListener.new(macros) } if macros.any?
        walked = SourceIntrospector.walk_source(record.source, listeners)

        declarations = DeclaredConstant.declarations(record.source)
        name = declarations.map(&:name).find { |n| n.casecmp?(record.path_name) } ||
               DeclaredConstant.resolve(record.source, record.path_name)
        SourceClass.new(name: name, methods: walked[:methods] || [], file: record.file,
                        macros: walked[:macros] || [],
                        parent_class: declarations.find { |d| d.name == name }&.superclass,
                        mixin: declarations.empty?, source: record.source)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "source_classes for #{record.path}")
      end

      # The file a loaded class was read from, root-relative; nil when the
      # constant has no source location or it lies outside the app. Compared
      # as real paths, the way app_defined? does, so a symlinked root keeps it.
      def source_file_for(klass)
        location = Object.const_source_location(klass.name)&.first
        return nil unless location

        real = File.realpath(location)
        root = app.root.to_s
        return nil unless SourceScan.under_root?(location, real, root, app_root_real)

        SourceScan.relative_file(location, real, root, app_root_real)
      rescue NameError, ArgumentError, TypeError, SystemCallError
        nil
      end

      def extract_channels
        return [] unless defined?(ActionCable::Channel::Base)

        # In development (config.eager_load = false), channel files are not
        # loaded until a client subscribes. Without this, .descendants is empty
        # and the entire channels array is missing from the introspector output.
        EagerLoad.dir(app.root, kind: "app/channels")

        ActionCable::Channel::Base.descendants.filter_map do |channel|
          next if channel.name.nil? || channel.name == "ApplicationCable::Channel"

          macros = channel_macros(channel_source(channel))

          {
            name:           channel.name,
            file:           source_file_for(channel),
            stream_methods: channel.instance_methods(false)
              .select { |m| m.to_s.start_with?("stream_") || m == :subscribed }
              .map(&:to_s),
            identified_by:  extract_identified_by(macros),
            streams:        extract_channel_streams(macros),
            periodic:       extract_channel_periodic(macros),
            actions:        extract_channel_actions(channel)
          }.compact
        end.sort_by { |c| c[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_channels")
      end

      def channel_source(channel)
        path = channel_absolute_path(channel)
        return nil unless path && File.exist?(path)
        RailsAiContext::SafeFile.read(path)
      end

      def channel_absolute_path(channel)
        method_source = channel.instance_methods(false).first
        return nil unless method_source
        location = channel.instance_method(method_source).source_location
        location&.first
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "channel_absolute_path")
      end

      # One walk for every channel macro: the three readers below filter what
      # it found rather than parsing the file again apiece.
      def channel_macros(source)
        return [] unless source
        SourceIntrospector.walk_source(source, {
          channel: -> { Listeners::GenericMacroListener.new(CHANNEL_MACROS) }
        })[:channel]
      end

      # `identified_by :current_user, :tenant` - declared on ApplicationCable::Connection,
      # but channels can also use it. Returns array of attribute names.
      def extract_identified_by(macros)
        hits = macros.select { |hit| hit[:macro] == :identified_by }
        return nil if hits.empty?
        hits.flat_map { |hit| hit[:args].map(&:to_s) }.uniq
      end

      # `stream_from "channel_name"` and `stream_for object` - what the channel broadcasts.
      def extract_channel_streams(macros)
        from_targets = macros.select { |hit| hit[:macro] == :stream_from }.filter_map { |hit| hit[:values].first&.to_s }
        for_targets  = macros.select { |hit| hit[:macro] == :stream_for }.filter_map { |hit| hit[:values].first&.to_s }
        result = {}
        result[:stream_from] = from_targets.uniq if from_targets.any?
        result[:stream_for]  = for_targets.uniq  if for_targets.any?
        result.empty? ? nil : result
      end

      # `periodically :method_name, every: 3.seconds`. The interval keeps its
      # source form so lambdas like `-> { current_user.interval }` survive whole.
      def extract_channel_periodic(macros)
        timers = macros.select { |hit| hit[:macro] == :periodically }.filter_map do |hit|
          method_name = hit[:args].first
          next unless method_name
          { method: method_name.to_s, every: hit[:option_values][:every].to_s }
        end
        timers.any? ? timers : nil
      end

      # RPC actions = public instance methods that aren't lifecycle hooks or stream helpers.
      def extract_channel_actions(channel)
        ignored = %i[subscribed unsubscribed]
        actions = channel.instance_methods(false).reject do |m|
          ignored.include?(m) || m.to_s.start_with?("stream_")
        end
        actions.empty? ? nil : actions.map(&:to_s).sort
      end
    end
  end
end
