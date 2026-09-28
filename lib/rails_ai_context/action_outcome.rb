# frozen_string_literal: true

module RailsAiContext
  # What a controller action answers, read from its body through Prism: a
  # redirect, a head status, a JSON or plain-text render, the implicit render,
  # or an answer that depends on a condition this reader does not evaluate.
  # Plots2's verify_email always redirects to /login; its shortlink redirects
  # when the user exists and raises when not.
  module ActionOutcome
    REDIRECTS = %i[redirect_to redirect_back redirect_back_or_to].freeze
    RESPONSES = (REDIRECTS + %i[head render raise respond_with]).freeze
    # The format and verb the test sends: a respond_to block and the
    # responders gem's respond_with both answer by them.
    Request = Struct.new(:format, :verb)
    # A condition on one of these is the scaffold's split between valid and
    # invalid params; the test sends valid ones.
    PERSISTENCE = %i[save save! update update! update_attributes destroy destroy! valid?].freeze

    module_function

    # @param def_node [Prism::DefNode] the action
    # @param methods [Hash{Symbol => Prism::DefNode}] the controller's other methods
    # @param format [Symbol] the format the test requests, which picks the
    #   `format.html` or `format.json` block of a `respond_to`
    # @return [Hash] `kind:` one of :render, :json, :plain, :redirect, :head or
    #   :conditional, with `status:` and `target:` (source) where they are known
    # @param verb [String] the HTTP verb the test sends
    def of(def_node, methods = {}, format: :html, verb: "get")
      request = Request.new(format, verb.to_s.downcase)
      statements_outcome(statements(def_node.body), methods, [ def_node.name ], request) || { kind: :render }
    end

    # The first answer the statements give, in order; nil when they give none
    # and the action falls through to its implicit render.
    def statements_outcome(nodes, methods, seen, request)
      nodes.each do |node|
        outcome = node_outcome(node, methods, seen, request)
        return outcome if outcome
      end
      nil
    end

    def node_outcome(node, methods, seen, request)
      case node
      when Prism::IfNode, Prism::UnlessNode
        if persistence?(node.predicate)
          valid = node.is_a?(Prism::IfNode) ? statements(node.statements) : else_branch(node.else_clause)
          outcome = valid && statements_outcome(valid, methods, seen, request)
          outcome && outcome[:kind] != :conditional ? outcome.merge(assumed_valid: true) : outcome
        else
          merge(branches(node).map { |branch| branch && statements_outcome(branch, methods, seen, request) })
        end
      when Prism::CaseNode
        merge(branches(node).map { |branch| branch && statements_outcome(branch, methods, seen, request) })
      # A bare return ends the action in its implicit render; `return
      # redirect_to x` answers with its argument.
      when Prism::ReturnNode
        answer = Array(node.arguments&.arguments).first
        (answer && node_outcome(answer, methods, seen, request)) || { kind: :render }
      when Prism::AndNode
        if node.right.is_a?(Prism::ReturnNode) && node.right.arguments.nil?
          node_outcome(node.left, methods, seen, request) || nested(node, methods, seen)
        else
          nested(node, methods, seen)
        end
      when Prism::CallNode
        if node.receiver.nil? && node.name == :respond_to && node.block.is_a?(Prism::BlockNode)
          statements_outcome(statements(node.block.body), methods, seen, request) || nested(node, methods, seen)
        elsif format_block?(node)
          node.name == request.format ? (statements_outcome(statements(node.block&.body), methods, seen, request) || { kind: :render }) : nil
        elsif node.receiver.nil? && RESPONSES.include?(node.name) && node.block.nil?
          response(node, request)
        elsif node.receiver.nil? && methods.key?(node.name) && !seen.include?(node.name)
          statements_outcome(statements(methods[node.name].body), methods, seen + [ node.name ], request)
        else
          nested(node, methods, seen)
        end
      else
        nested(node, methods, seen)
      end
    end

    # `if @post.save`, `unless @post.update(post_params)`, `if @post.destroy`.
    def persistence?(predicate)
      predicate.is_a?(Prism::CallNode) && !predicate.receiver.nil? && PERSISTENCE.include?(predicate.name)
    end

    # `format.html { ... }` inside a respond_to block.
    def format_block?(node)
      node.receiver.is_a?(Prism::LocalVariableReadNode) && node.receiver.name == :format && %i[html json js xml turbo_stream any].include?(node.name)
    end

    # An answer given somewhere inside a block, a rescue or `x or redirect_to`
    # is one that depends on how the code runs.
    def nested(node, methods, seen)
      Introspectors::AstWalk.each(node).any? { |inner| answering_call?(inner, methods, seen) } ? { kind: :conditional } : nil
    end

    # Whether a helper answers anywhere in its body, or through a helper it calls.
    def answers?(name, methods, seen)
      return false unless methods.key?(name) && !seen.include?(name)

      Introspectors::AstWalk.each(methods[name]).any? { |inner| answering_call?(inner, methods, seen + [ name ]) }
    end

    # A call that answers the request: a response itself, or a helper that gives one.
    def answering_call?(node, methods, seen)
      node.is_a?(Prism::CallNode) && node.receiver.nil? &&
        (RESPONSES.include?(node.name) || answers?(node.name, methods, seen))
    end

    # Branches that all answer alike are one answer; branches that all fall
    # through are none; anything else depends on the condition.
    def merge(outcomes)
      return nil if outcomes.all?(&:nil?)
      return { kind: :conditional } if outcomes.any?(&:nil?)

      first = outcomes.first
      same = outcomes.all? { |outcome| outcome[:kind] == first[:kind] && outcome[:status] == first[:status] }
      return { kind: :conditional } unless same && first[:kind] != :conditional

      outcomes.all? { |outcome| outcome == first } ? first : first.except(:target)
    end

    def branches(node)
      case node
      when Prism::IfNode
        [ statements(node.statements), else_branch(node.subsequent) ]
      when Prism::UnlessNode
        [ statements(node.statements), else_branch(node.else_clause) ]
      when Prism::CaseNode
        node.conditions.map { |condition| statements(condition.statements) } + [ else_branch(node.else_clause) ]
      end
    end

    # nil for a missing else: the condition may answer nothing at all.
    def else_branch(node)
      case node
      when nil then nil
      when Prism::ElseNode then statements(node.statements)
      else [ node ]
      end
    end

    def statements(node)
      case node
      when nil then []
      when Prism::StatementsNode then node.body
      when Prism::BeginNode then node.rescue_clause || node.ensure_clause ? [ node ] : statements(node.statements)
      else [ node ]
      end
    end

    def response(node, request)
      args = Array(node.arguments&.arguments)
      case node.name
      when :raise then { kind: :conditional }
      when :respond_with then responder_outcome(request)
      when :head then status_outcome(:head, args.first)
      when :render then render_outcome(args)
      else redirect_outcome(node.name, args)
      end
    end

    # How the responders gem answers respond_with with valid params: HTML
    # renders a read and redirects a write; JSON renders a read, answers a
    # create with 201 and the resource, and an update or destroy with 204.
    def responder_outcome(request)
      read = %w[get head].include?(request.verb)
      if request.format == :json
        return { kind: :json, content_type: "application/json" } if read
        return { kind: :json, status: :created, content_type: "application/json", assumed_valid: true } if request.verb == "post"

        { kind: :head, status: :no_content, assumed_valid: true }
      else
        read ? { kind: :render } : { kind: :redirect, assumed_valid: true }
      end
    end

    # A redirect's literal `status:` (`:see_other` after a destroy) is its answer.
    def redirect_outcome(name, args)
      given = options_of(args)[:status]
      status = given && status_value(given)
      return { kind: :conditional } if given && status.nil?

      { kind: :redirect, status: status, target: redirect_target(name, args.first) }.compact
    end

    def options_of(args)
      args.grep(Prism::KeywordHashNode).flat_map(&:elements).to_h do |pair|
        [ pair.key.is_a?(Prism::SymbolNode) ? pair.key.unescaped.to_sym : nil, pair.value ]
      end
    end

    def render_outcome(args)
      options = options_of(args)
      kind = if options.key?(:json) then :json
      elsif options.key?(:plain) then :plain
      else :render
      end
      status = options[:status] && status_value(options[:status])
      return { kind: :conditional } if options.key?(:status) && status.nil?

      { kind: kind, status: status, content_type: content_type(kind, options) }.compact
    end

    # The media type the render sets: its `content_type:` when that is a
    # literal (an API can render JSON through `render plain:, content_type:`),
    # none to assert when it is computed, else the kind's own.
    def content_type(kind, options)
      given = options[:content_type]
      return given.unescaped.split(";").first.strip if given.is_a?(Prism::StringNode)
      return :unknown if given

      { json: "application/json", plain: "text/plain" }[kind]
    end

    def status_outcome(kind, node)
      status = status_value(node)
      status ? { kind: kind, status: status } : { kind: :conditional }
    end

    def status_value(node)
      case node
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::IntegerNode then node.value
      end
    end

    # A target the test can name: a literal path, or a route helper called
    # with no arguments. A target built from the record is left unnamed.
    def redirect_target(name, node)
      return nil unless name == :redirect_to

      case node
      when Prism::StringNode then node.slice
      when Prism::CallNode
        node.slice if node.receiver.nil? && node.arguments.nil? && node.name.to_s.end_with?("_path", "_url")
      end
    end
  end
end
