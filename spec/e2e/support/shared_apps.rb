# frozen_string_literal: true

module E2E
  # Shared Rails-app fixtures across e2e specs.
  #
  # Several specs (mcp_stdio_protocol, mcp_http_protocol, concurrent_mcp,
  # tool_edge_cases) exercise the same `:in_gemfile` app in a read-only way
  # - they spawn CLI / MCP subprocesses but never mutate the app tree. Each
  # spec rebuilding its own Rails app is wasted wall-clock. This helper
  # memoizes one built app per (install_path, scaffold) key per rspec
  # process.
  #
  # Exceptions that MUST keep their own dedicated app:
  #   - in_gemfile_install_spec - its idempotency test re-runs the generator
  #     with different stdin ("a\nn\n1\nn\n" vs build's "a\n1\nn\n") and
  #     would mutate the shared fixture (rspec runs in random order, so we
  #     can't guarantee it runs last).
  #   - empty_app_spec - deliberately built with `scaffold_sample_model!`
  #     stubbed out, so it has no Post model / controller / routes.
  #
  # Everything else that reads from an in-Gemfile install can call
  # `E2E.shared_app(install_path: :in_gemfile)`.
  def self.shared_app(install_path:, scaffold: true)
    @shared_apps ||= {}
    key = [ install_path, scaffold ]
    @shared_apps[key] ||= begin
      name = "shared_#{install_path}#{scaffold ? '' : '_bare'}"
      builder = TestAppBuilder.new(
        parent_dir: root,
        name: name,
        install_path: install_path
      )
      unless scaffold
        builder.define_singleton_method(:scaffold_sample_model!) { }
      end
      builder.build!
    end
  end
end
