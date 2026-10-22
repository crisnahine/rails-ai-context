# frozen_string_literal: true

require "find"
require "open3"
require "prism"

module RailsAiContext
  # The security settings an app's Ruby config writes, read without running it. The static tier runs
  # no initializer, so a pattern a configure block added to sensitive_patterns was dropped there and
  # the file it names was served. Each literal written to a key is added on top of the YAML; a removal
  # is left out, the stricter reading; anything the reader cannot follow refuses the static tier. A
  # file under config/ is read whole, and so is the top level of any other file that names the gem,
  # which runs as the file loads; a method's body there, a tool's or a helper's that runs when
  # called, is read for what it writes.
  module InitializerSettings
    KEYS = %i[sensitive_patterns excluded_paths skip_tools].freeze
    # Each returns the array, so `<<` chains append to it too, and so do these removals.
    ADDS = %i[<< push append concat unshift prepend insert].freeze
    SELF_REMOVES = %i[delete_if reject! select! filter! keep_if clear].freeze
    REMOVES = (SELF_REMOVES + %i[delete delete_at pop shift]).freeze
    # Reads that change nothing and hand back nothing of the array's own, called with no block.
    READS = %i[size length count empty? any? none? include? join inspect to_s frozen?].freeze
    # Reads that take a block of each pattern. Under config/ the value of a LIVE one, which can hold
    # the array or its patterns, is not to be kept.
    ITERATORS = %i[each each_with_index map flat_map filter_map collect select filter reject find detect any? all? none? count sum
                   min_by max_by sort_by group_by partition find_index index].freeze
    LIVE = (ADDS + SELF_REMOVES + %i[each each_with_index select filter reject find detect min_by max_by sort_by group_by partition
                                      map flat_map filter_map collect dup clone to_a entries]).freeze
    # What changes a pattern string in place, and the calls that hand back the string they are called on.
    MUTATORS = %i[<< concat replace insert prepend clear []= setbyte force_encoding].freeze
    ELEMENT_SELF = %i[itself to_s to_str +@ freeze presence].freeze
    # Calls whose block's value goes nowhere, so a statement ending the block keeps nothing: the
    # configure call, Rails' hooks, the iterators that hand back their receiver. Any other call may
    # hand the block's value back (`then`, `synchronize`, `fetch`), so it counts as kept.
    DISCARDING = %i[configure before_configuration before_initialize before_eager_load after_initialize after_routes_loaded
                    to_prepare to_run to_complete on_load initializer console rake_tasks generators server runner
                    included extended prepended class_methods subscribe monotonic_subscribe task namespace
                    each each_with_index each_with_object each_key each_value each_pair each_slice each_cons each_char each_line
                    each_byte reverse_each times upto downto step loop tap delete_if keep_if reject! select! filter!].freeze
    # Calls on a list that hand back one of its patterns, and calls that hand back a copy holding the same patterns.
    ELEMENT_GETTERS = %i[first last [] at fetch dig sample min max find detect slice].freeze
    COPIES = %i[dup clone to_a entries take drop reverse uniq compact sort sort_by min_by max_by first last values_at
                each_slice select filter reject].freeze
    # Calls naming a local by a string, which can reach the configure block's param past any read of it.
    EVALS = %i[binding eval].freeze
    # Calls that turn a name into the module or the configuration.
    REFLECTIVE = %i[const_get send public_send __send__ instance_variable_get method public_method instance_method
                    eval instance_eval class_eval module_eval constantize safe_constantize].freeze
    GEM_NAME = /\A(?:::)?(?:RailsAiContext(?:::|\z)|rails_ai_context\z)/
    # Folders the app does not run as it boots, or that only tools write, at the top; at any depth, its
    # tests (an engine's test app among them), an installed copy of this gem and a generator's templates.
    UNBOOTED = %w[db tmp log node_modules coverage public vendor/bundle vendor/ruby vendor/cache vendor/gems].freeze
    UNBOOTED_ANYWHERE = %w[spec test].freeze
    GEM_COPY = /\Arails-ai-context(?:-\d.*)?\z/
    UNBOOTED_GLOBS = [ *UNBOOTED.map { |dir| "!/#{dir}/" }, *UNBOOTED_ANYWHERE.map { |dir| "!#{dir}/" }, "!rails-ai-context/",
                       "!rails-ai-context-[0-9]*/", "!**/generators/**/templates/**" ].freeze
    # A file Rails runs as configuration is read whole.
    CONFIG = %r{(?:\A|/)config/}
    # Deeper than any configuration nests; read no further, so the reader never runs out of stack.
    MAX_DEPTH = 1000
    # Rails globs these through a link, which neither search below follows.
    BOOT_GLOBS = %w[config/initializers/**/*.rb config/environments/*.rb].freeze
    # A block in these runs before .rails-ai-context.yml is read, and a key it assigns keeps the YAML off that key.
    BEFORE_YAML = %r{\Aconfig/(?:application|environments/[^/]+)\.rb\z}
    # Ruby config files are small; a larger one is searched for the gem's name before it is refused.
    MAX_SOURCE = 10_000_000
    MARKERS = %w[RailsAiContext rails_ai_context].freeze

    Found = Struct.new(:values, :assigned, :refusals)

    module_function

    # Every Ruby file of the app that names the gem, however the boot reaches it.
    #
    # @raise [ConfigurationError] naming the first line it could not read
    def apply!(root, config = RailsAiContext.configuration)
      root = File.expand_path(root.to_s)
      found = boot_files(root).to_h { |relative| [ relative, read(File.join(root, relative), relative) ] }
      if (file, line, what = found.values.flat_map(&:refusals).first)
        raise ConfigurationError, "#{file}:#{line}: the static tier cannot read #{what} without booting the app, so it serves nothing: " \
          "the file a setting there keeps back would be read. Write the value as a literal list, such as %w[config/keys.yml], " \
          "or set it in .rails-ai-context.yml, which every tier reads."
      end

      defaults = Configuration.new
      KEYS.each do |key|
        added = found.values.flat_map { |each| each.values[key] }
        added += defaults.public_send(key) if found.any? { |relative, each| relative.match?(BEFORE_YAML) && each.assigned.include?(key) }
        config.public_send(:"#{key}=", (config.public_send(key) + added.map(&:to_s)).uniq) if added.any?
      end
    end

    # The Ruby files that name the gem, hidden files, links and folders the boot does not run aside,
    # with config/initializers and config/environments read through a link as Rails globs them. A file
    # required by a computed path, autoloaded or in an engine is read with the rest; one outside the
    # app is not. ripgrep finds them when it is there; the walk lists the same files without it.
    def boot_files(root)
      found = (Executable.on_path?("rg") && ripgrep_files(root)) || walked_files(root).select { |relative| names_gem?(File.join(root, relative)) }
      (found + Dir.glob(BOOT_GLOBS, base: root).select { |relative| names_gem?(File.join(root, relative)) }).uniq.sort
    end

    # nil when ripgrep fails, so the walk answers instead. It reads a file with a NUL in it as Ruby does,
    # and names come back split on NUL, which no file name holds.
    def ripgrep_files(root)
      globs = [ "*.rb", "!.*", *UNBOOTED_GLOBS ].flat_map { |glob| [ "-g", glob ] }
      markers = MARKERS.flat_map { |marker| [ "-e", marker ] }
      # The path is given, or ripgrep searches its standard input, which a pipe is.
      out, status = Open3.capture2("rg", "--files-with-matches", "--fixed-strings", "--no-ignore", "--no-messages", "--text", "--null",
                                   "--path-separator", "/", *globs, *markers, ".", chdir: root, err: File::NULL)
      out.split("\0").map { |path| path.delete_prefix("./") } if status.success? || status.exitstatus == 1
    rescue SystemCallError
      nil
    end

    def walked_files(root)
      files = []
      Find.find(root) do |path|
        next if path == root

        relative = path.delete_prefix("#{root}/")
        name = File.basename(path)
        next Find.prune if name.start_with?(".") || File.symlink?(path) || UNBOOTED.include?(relative)
        next Find.prune if File.directory?(path) && (UNBOOTED_ANYWHERE.include?(name) || name.match?(GEM_COPY) ||
                                                   (name == "templates" && relative.match?(%r{(?:\A|/)generators/})))

        files << relative if path.end_with?(".rb") && File.file?(path)
      end
      files
    end

    # A file that cannot be read whole is read a line at a time, and taken to name the gem when it cannot be read at all.
    def names_gem?(path)
      File.foreach(path).any? { |line| MARKERS.any? { |marker| line.include?(marker) } }
    rescue SystemCallError, ArgumentError
      true
    end

    def read(path, relative)
      found = Found.new(Hash.new { |hash, key| hash[key] = [] }, Set.new, [])
      source = SafeFile.read(path, max_size: MAX_SOURCE)
      result = source && AstCache.parse_string(source)
      if result.nil? || result.errors.any?
        found.refusals << [ relative, result ? result.errors.first.location.start_line : 1, "this file" ]
      elsif too_deep?(result.value)
        found.refusals << [ relative, 1, "this file" ]
      else
        Reader.new(found, relative, config: relative.match?(CONFIG)).visit(result.value)
      end
      found
    rescue SystemStackError
      found.refusals.unshift([ relative, 1, "this file" ])
      found
    end

    def too_deep?(node)
      stack = [ [ node, 1 ] ]
      until stack.empty?
        current, depth = stack.pop
        return true if depth > MAX_DEPTH

        current.compact_child_nodes.each { |child| stack << [ child, depth + 1 ] }
      end
      false
    end

    # Roots are the configure block's param, RailsAiContext.configuration and the app config's
    # rails_ai_context. A root may only receive a call the configuration's API names, a key's value
    # only an add, a removal or a read, and the module only its own calls: anything else could change
    # a setting where this reader cannot see. Strict, under config/ and at the top of any file, the
    # list and its patterns are not to be kept or handed on either; in a method outside config/, only
    # what changes them is held back.
    class Reader < Prism::Visitor
      API = Configuration.public_instance_methods(false).to_set.freeze
      MODULE_API = (RailsAiContext.singleton_methods(false).reject { |name| name.end_with?("=") } + %i[respond_to?]).to_set.freeze

      def initialize(found, file, config: true)
        super()
        @found = found
        @file = file
        @config = config
        @methods = 0
        @roots = []
        @elements = []
        @used = [ false ]
        @consumed = Set.new.compare_by_identity
        @statements = Set.new.compare_by_identity
        @chained = Set.new.compare_by_identity
        @discarding = Set.new.compare_by_identity
        @keys = {}.compare_by_identity
        @element_of = {}.compare_by_identity
        @frames = Hash.new { |hash, name| hash[name] = [] }
      end

      # A statement's value goes nowhere, but the last one's is the value of what holds it: a block's, a
      # method's, the parentheses' or a condition's, kept when that is.
      def visit_statements_node(node)
        @statements.merge(@used.last ? node.body[0...-1] : node.body)
        super
      end

      %i[parentheses if unless case case_match begin].each do |type|
        define_method(:"visit_#{type}_node") do |node|
          @used.push(!@statements.include?(node))
          super(node)
        ensure
          @used.pop
        end
      end

      def visit_def_node(node)
        @used.push(true)
        @methods += 1
        super
      ensure
        @methods -= 1
        @used.pop
      end

      def visit_lambda_node(node)
        @used.push(true)
        super
      ensure
        @used.pop
      end

      # A block given each pattern is read once, by each_element.
      def visit_block_node(node)
        return if @consumed.include?(node)

        @used.push(!@discarding.include?(node))
        super
      ensure
        @used.pop unless @consumed.include?(node)
      end

      def visit_call_node(node)
        receiver = node.receiver
        @discarding << node.block if node.block && DISCARDING.include?(node.name)
        # A read of a list (`.join`, `.size`) hands back something new, so the list it reads is not kept.
        @chained << unwrap(receiver) if receiver && READS.include?(node.name) && !node.block
        return refuse(node, node.name) if receiver.nil? && EVALS.include?(node.name) && @roots.any?
        return refuse(node, "RailsAiContext") if REFLECTIVE.include?(node.name) && [ receiver, *node.arguments&.arguments ].any? { |arg| gem_name?(arg) }
        return element_call(node) if element?(receiver)

        if gem_constant?(receiver)
          @consumed << receiver
          return refuse(node, "RailsAiContext") unless MODULE_API.include?(node.name)
          return configure(node) if node.name == :configure
        end

        if root?(receiver)
          @consumed << receiver
          key = node.name.to_s.delete_suffix("=").to_sym
          if node.block || !(API.include?(node.name) || node.name == :respond_to?)
            refuse(node, root_name(receiver))
          elsif node.name.end_with?("=") && KEYS.include?(key)
            add(node, key, assigned(node, key), assigned: true)
          elsif KEYS.include?(node.name) && !@consumed.include?(node) && strict?
            refuse(node, node.name)
          end
        elsif !@consumed.include?(node) && (key = target_key(receiver))
          mutate(node, key)
        elsif root?(node) && !@consumed.include?(node)
          refuse(node, root_name(node))
        end
        super
      end

      def visit_call_operator_write_node(node)
        write(node) { %i[+ |].include?(node.binary_operator) ? :add : (%i[- &].include?(node.binary_operator) ? :remove : nil) }
      end

      def visit_call_or_write_node(node)
        write(node) { :add }
      end

      def visit_call_and_write_node(node)
        write(node) { :add }
      end

      # The configuration handed on is changed where this reader cannot see; a pattern handed on, only
      # under config/.
      def visit_local_variable_read_node(node)
        handed(node, node.name)
        super
      end

      def visit_it_local_variable_read_node(node)
        handed(node, :it)
        super
      end

      def visit_constant_read_node(node)
        refuse(node, "RailsAiContext") if node.name == :RailsAiContext && !@consumed.include?(node)
        super
      end

      # RailsAiContext::Engine names a class the app may mount; RailsAiContext::Configuration is the
      # settings themselves. Outside config/ a constant of it may be read.
      def visit_constant_path_node(node)
        parent = node.parent
        @consumed << parent if !strict? && parent.is_a?(Prism::ConstantPathNode) && parent.name == :Configuration && gem_constant?(parent.parent)
        if gem_constant?(node.parent)
          @consumed << node.parent
          refuse(node, "RailsAiContext::Configuration") if node.name == :Configuration && (strict? || !@consumed.include?(node))
        elsif gem_constant?(node) && !@consumed.include?(node)
          refuse(node, "RailsAiContext")
        end
        super
      end

      # Outside config/ a tool may open the gem's namespace to sit in it; never its configuration's class.
      def visit_module_node(node)
        @consumed << node.constant_path if !@config && gem_constant?(node.constant_path)
        super
      end


      # What `defined?` names is not run.
      def visit_defined_node(_node); end

      private

      def gem_name?(node)
        (node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)) && node.unescaped.match?(GEM_NAME)
      end

      # Strict under config/ and outside any method: a method elsewhere runs when called, not as its file loads.
      def strict?
        @config || @methods.zero?
      end

      def handed(node, name)
        return if @consumed.include?(node)

        if @roots.include?(name)
          refuse(node, name)
        elsif (frame = element_frame(name)) && strict?
          refuse(node, frame.last)
        end
      end

      def element_frame(name)
        @frames[name].last
      end

      def configure(node)
        visit(node.arguments)
        return refuse(node, "RailsAiContext.configure") unless node.block.is_a?(Prism::BlockNode)

        param = block_param(node.block)
        return refuse(node, what: "the parameters of this configure block") if param == :unread

        @roots.push(param)
        visit(node.block)
      ensure
        @roots.pop if param && param != :unread
      end

      def write(node)
        # Another setting is the configuration's own business, written any way the API allows.
        if root?(node.receiver) && !KEYS.include?(node.read_name)
          @consumed << node.receiver
          refuse(node, root_name(node.receiver)) unless API.include?(node.read_name)
          return node.value.accept(self)
        end
        return super_write(node) unless root?(node.receiver) && KEYS.include?(node.read_name)

        @consumed << node.receiver
        case yield
        when :add then add(node, node.read_name, literals(node.value), assigned: true)
        when :remove then @found.assigned << node.read_name
        else refuse(node, node.read_name)
        end
        super_write(node)
      end

      def super_write(node)
        node.compact_child_nodes.each { |child| child.accept(self) }
      end

      # The literals a setter is given, `key = key + [...]` and `key = key | [...]` among them.
      def assigned(node, key)
        value = node.arguments&.arguments&.first
        if value.is_a?(Prism::CallNode) && %i[+ |].include?(value.name) && value.arguments&.arguments&.size == 1
          other = value.arguments.arguments.first
          return literals(other) if key_read?(value.receiver, key) && @consumed.add(value.receiver).add(value)
          return literals(value.receiver) if value.name == :+ && key_read?(other, key) && @consumed.add(other).add(value)
        end
        literals(value)
      end

      def key_read?(node, key)
        node.is_a?(Prism::CallNode) && node.name == key && node.arguments.nil? && root?(node.receiver)
      end

      # The key whose array `node` is: a read of it off a root, or a call chained on one that returns
      # the array (`<< "a" << "b"`, `.clear.concat(...)`), parentheses or begin around either. Each link
      # remembers its key, so a chain is walked once however long.
      def target_key(node)
        chain = []
        node = unwrap(node)
        while node.is_a?(Prism::CallNode) && (ADDS + SELF_REMOVES).include?(node.name) && !root?(node.receiver) && !@keys.key?(node)
          chain << node
          node = unwrap(node.receiver)
        end
        key = @keys.key?(node) ? @keys[node] : key_read(node)
        chain.each { |link| @keys[link] = key }
        key
      end

      # The key a read off a root names, or nil.
      def key_read(node)
        return nil unless node.is_a?(Prism::CallNode) && KEYS.include?(node.name) && node.arguments.nil? && root?(node.receiver)

        @consumed << node
        node.name
      end

      def unwrap(node)
        loop do
          body = node.body if node.is_a?(Prism::ParenthesesNode)
          body = node.statements if node.is_a?(Prism::BeginNode) && !node.rescue_clause && !node.else_clause && !node.ensure_clause
          break node unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

          node = body.body.first
        end
      end

      def mutate(node, key)
        @chained << unwrap(node.receiver)
        # The array an add or a removal returns is the setting's own: kept anywhere, it is changed unseen.
        return refuse(node, key) if strict? && LIVE.include?(node.name) && !@statements.include?(node) && !@chained.include?(node)
        return each_element(node, key) if REMOVES.include?(node.name) || ITERATORS.include?(node.name) || (READS.include?(node.name) && !node.block)
        unless ADDS.include?(node.name) && !node.block
          return refuse(node, key) if strict? || node.block || node.name.end_with?("!") || %i[[]= fill replace].include?(node.name)

          return
        end

        args = node.arguments&.arguments || []
        args = args.drop(1) if node.name == :insert && args.first.is_a?(Prism::IntegerNode)
        values = args.map { |arg| literals(arg.is_a?(Prism::SplatNode) ? arg.expression : arg) }
        add(node, key, values.all? ? values.flatten : nil)
      end

      # A block given each pattern may read it, never change it in place or hand it on.
      def each_element(node, key)
        block = node.block
        case block
        when nil then nil
        when Prism::BlockArgumentNode
          symbol = block.expression
          refuse(node, key) unless symbol.is_a?(Prism::SymbolNode) && !mutator?(symbol.unescaped.to_sym)
        else
          param = block_param(block)
          return refuse(node, key) if param == :unread

          frame = [ param, key ]
          @elements.push(frame)
          @frames[param] << frame
          visit(block)
          @frames[param].pop
          @elements.pop
          @consumed << block
        end
      end

      # The frame of the block whose pattern node is, itself or through a call that hands it back
      # (`p.to_s`, `+p`), at any depth of blocks. Each call remembers its answer, so a long run of such
      # calls is walked once.
      def element?(node)
        node = unwrap(node)
        return @element_of[node] if @element_of.key?(node)

        @element_of[node] =
          case node
          when Prism::CallNode then element_call_frame(node)
          when Prism::LocalVariableReadNode then element_frame(node.name)
          when Prism::ItLocalVariableReadNode then element_frame(:it)
          end
      end

      # A call that hands back a pattern: one on a pattern that returns it (`p.to_s`), or one on a list
      # that returns one of its patterns (`list.last`).
      def element_call_frame(node)
        return nil unless node.receiver

        if ELEMENT_SELF.include?(node.name) && !node.block
          element?(node.receiver)
        elsif ELEMENT_GETTERS.include?(node.name) && (key = target_key(list_under_copies(node.receiver)))
          [ nil, key ]
        end
      end

      # The list a run of copies (`.dup`, `.take(1)`) starts from.
      def list_under_copies(node)
        node = unwrap(node)
        node = unwrap(node.receiver) while node.is_a?(Prism::CallNode) && COPIES.include?(node.name) && node.receiver && !root?(node.receiver)
        node
      end

      def element_call(node)
        frame = element?(node.receiver)
        @consumed << node.receiver
        @consumed << unwrap(node.receiver)
        refuse(node, frame.last) if mutator?(node.name) || node.block
        super_call(node)
      end

      def mutator?(name)
        name.end_with?("!") || MUTATORS.include?(name)
      end

      def super_call(node)
        node.compact_child_nodes.each { |child| child.accept(self) }
      end

      def add(node, key, values, assigned: false)
        return refuse(node, key) if values.nil?

        @found.assigned << key if assigned
        @found.values[key].concat(values)
      end

      # The strings a value holds, or nil when it is no literal: a string or a symbol, an array of
      # them, `.freeze` on one, or a condition each of whose branches is one.
      def literals(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then [ node.unescaped ]
        when Prism::NilNode then []
        when Prism::ArrayNode
          values = node.elements.map { |element| literals(element.is_a?(Prism::SplatNode) ? element.expression : element) }
          values.flatten if values.all?
        when Prism::CallNode then literals(node.receiver) if node.name == :freeze && node.receiver && node.arguments.nil?
        when Prism::ParenthesesNode then literals(node.body.body.first) if node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
        when Prism::IfNode, Prism::UnlessNode
          other = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
          branches = [ node.statements, other.is_a?(Prism::ElseNode) ? other.statements : other ]
          values = branches.map { |branch| branch.nil? ? [] : literals(branch.is_a?(Prism::StatementsNode) ? branch.body.last : branch) }
          values.flatten if values.all?
        end
      end

      def root?(node)
        case node
        when Prism::LocalVariableReadNode then @roots.include?(node.name)
        when Prism::ItLocalVariableReadNode then @roots.include?(:it)
        when Prism::CallNode
          return false unless node.arguments.nil?

          # config.x is the app's own namespace, which the gem does not read.
          (node.name == :configuration && gem_constant?(node.receiver)) ||
            (node.name == :rails_ai_context && !node.receiver.nil? && !(node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :x))
        else false
        end
      end

      def root_name(node)
        case node
        when Prism::CallNode then node.name == :rails_ai_context ? "config.rails_ai_context" : "RailsAiContext.configuration"
        when Prism::ItLocalVariableReadNode then :it
        else node.name
        end
      end

      # RailsAiContext, ::RailsAiContext or Object::RailsAiContext.
      def gem_constant?(node, name = :RailsAiContext)
        return false unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        return false unless node.name == name
        return true if node.is_a?(Prism::ConstantReadNode) || node.parent.nil?

        name == :RailsAiContext && gem_constant?(node.parent, :Object)
      end

      # The name the block binds the configuration to: nil for none, :unread for a shape this reader does not follow.
      def block_param(block)
        params = block.parameters
        case params
        when nil then nil
        when Prism::NumberedParametersNode then :_1
        when Prism::ItParametersNode then :it
        when Prism::BlockParametersNode
          list = params.parameters
          return nil if list.nil?

          plain = list.requireds.size == 1 && list.requireds.first.is_a?(Prism::RequiredParameterNode) && list.optionals.empty? &&
            list.rest.nil? && list.posts.empty? && list.keywords.empty? && list.keyword_rest.nil? && list.block.nil?
          plain ? list.requireds.first.name : :unread
        else :unread
        end
      end

      def refuse(node, name = nil, what: "what this line does to `#{name}`")
        @found.refusals << [ @file, node.location.start_line, what ]
        nil
      end
    end
  end
end
