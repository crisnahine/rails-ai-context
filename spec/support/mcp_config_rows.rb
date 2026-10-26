# frozen_string_literal: true

require "json"

# What the install does with each MCP config text, one row each: the write
# path and doctor are both checked against it.
module McpConfigRows
  module_function

  # @return [Hash{String => Array(Symbol, String, Hash)}] shape => [tool, text, expected verdict]
  def rows
    not_json_client = "Claude Code cannot read it: it holds a trailing comma, which JSON does not allow"
    next_run = ", and the next run merges into it"
    ours = { "command" => "rails-ai-context", "args" => [ "serve" ] }
    comments_entry = JSON.generate("servers" => { "rails-ai-context" => ours })
    {
      "no file" => [ :claude, nil, { action: :write, reason: nil, by_hand: nil, readable: true } ],
      "an empty file" => [ :claude, "\n", { action: :write, reason: nil, by_hand: nil, readable: true } ],
      "a config without the gem's server" => [ :claude, %({"mcpServers":{"other":{"command":"x"}}}),
                                               { action: :merge, reason: nil, by_hand: nil, readable: true } ],
      "a config holding the gem's server as the install writes it" => [
        :claude, JSON.generate("mcpServers" => { "rails-ai-context" => ours }),
        { action: :keep, reason: nil, by_hand: nil, readable: true }
      ],
      "a JSON config that is not UTF-8" => [ :claude, %({"mcpServers":{"x":{"command":"caf\xE9"}}}).b,
                                             { action: :refuse, reason: "it is not UTF-8, which JSON is",
                                               by_hand: "Save it as UTF-8#{next_run}", readable: false } ],
      "a trailing comma in a config its client reads as JSON" => [ :claude, %({"mcpServers":{},}),
                                                                   { action: :refuse, reason: not_json_client,
                                                                     by_hand: "Make it plain JSON by hand#{next_run}", readable: false } ],
      "a config that does not parse" => [ :claude, "not json{{{",
                                          { action: :refuse, reason: /\Ait does not parse as JSON/,
                                            by_hand: "Make it valid JSON holding an object#{next_run}", readable: false } ],
      "JSON that is no object" => [ :claude, "[1, 2]",
                                    { action: :refuse, reason: "it is JSON but not an object",
                                      by_hand: "Make it a JSON object#{next_run}", readable: false } ],
      "a servers key that is no object" => [ :copilot, %({"servers": ["x"]}),
                                             { action: :refuse, reason: %("servers" is not an object),
                                               by_hand: %(Make "servers" in it an object#{next_run}), readable: false } ],
      "comments in a JSONC config that lacks the gem's server" => [
        :copilot, %({\n  // mine\n  "servers": {}\n}\n),
        { action: :refuse, reason: RailsAiContext::McpConfigGenerator::COMMENTS_PROBLEM,
          by_hand: "Add #{comments_entry} to it by hand", readable: true }
      ],
      "comments in a JSONC config that holds it as written" => [
        :copilot, %({\n  // mine\n  "servers": #{JSON.generate("rails-ai-context" => ours)}\n}\n),
        { action: :keep, reason: nil, by_hand: nil, readable: true }
      ],
      "an HTTP entry under the gem's name" => [
        :claude, JSON.generate("mcpServers" => { "rails-ai-context" => { "url" => "http://localhost:6029/mcp" } }),
        { action: :keep, reason: nil, by_hand: nil, readable: true, note: /reaches the gem's HTTP endpoint/ }
      ],
      "the gem's Codex entry as an inline table" => [
        :codex, %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context", args = ["serve"] }\n),
        { action: :refuse, reason: "it sets rails-ai-context as an inline table or with dotted keys, which the install does not rewrite",
          by_hand: "Write it as a [mcp_servers.rails-ai-context] table by hand, or delete it, and the next run keeps it current",
          readable: true }
      ],
      "Codex servers as one inline table" => [
        :codex, %(mcp_servers = { other = { command = "x" } }\n),
        { action: :refuse, reason: /\Aits mcp_servers is an inline table/,
          by_hand: "Write it as [mcp_servers.<name>] tables by hand", readable: true }
      ],
      "Codex servers as one inline table beside a table of the gem's" => [
        :codex, %(mcp_servers = { other = { command = "x" } }\n\n[mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\n),
        { action: :refuse, reason: /, yet it holds one, which Codex refuses to read\z/,
          by_hand: "Delete one of them by hand", readable: false }
      ],
      "the gem's Codex table twice" => [
        :codex, %([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\nargs = ["serve"]\n\n) +
                %([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\nargs = ["serve"]\n),
        { action: :merge, reason: "it declares rails-ai-context twice, which Codex refuses to read", by_hand: nil, readable: false }
      ],
      "the gem's Codex entry twice, once inline" => [
        :codex, %([mcp_servers]\nrails-ai-context = { command = "a" }\n\n[mcp_servers.rails-ai-context]\ncommand = "b"\n),
        { action: :refuse, reason: "it declares rails-ai-context twice, which Codex refuses to read",
          by_hand: "Delete all but one by hand", readable: false }
      ],
      "a Codex config that is not UTF-8" => [
        :codex, %([mcp_servers.other]\ncommand = "caf\xE9"\n).b,
        { action: :merge, reason: RailsAiContext::McpConfigGenerator::TOML_NOT_UTF8, by_hand: "Save it as UTF-8", readable: false,
          note: RailsAiContext::McpConfigGenerator::TOML_NOT_UTF8 }
      ]
    }
  end
end
