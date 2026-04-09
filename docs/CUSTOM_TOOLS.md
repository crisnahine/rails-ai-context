<div align="center">

# Custom Tools

**Build your own MCP tools that run alongside the 38 built-in ones.**

[Tools Reference](TOOLS.md) · [Configuration](CONFIGURATION.md) · [Architecture](ARCHITECTURE.md) · [FAQ](FAQ.md)

</div>

---

> [!NOTE]
> Custom tools have full access to your Rails environment — ActiveRecord, services, mailers, everything. They appear alongside the 38 built-in tools in both MCP and CLI.

## Creating a custom tool

Custom tools are subclasses of `MCP::Tool` that you register in your configuration.

```ruby
# app/mcp_tools/rails_get_business_metrics.rb
class RailsGetBusinessMetrics < MCP::Tool
  tool_name "rails_get_business_metrics"
  description "Returns key business metrics for the current environment"

  input_schema(
    properties: {
      period: {
        type: "string",
        description: "Time period: day, week, month",
        enum: %w[day week month]
      }
    }
  )

  def call(period: "week")
    # Your logic here — full access to Rails models, services, etc.
    stats = {
      users: User.where("created_at > ?", period_start(period)).count,
      orders: Order.where("created_at > ?", period_start(period)).count,
      revenue: Order.where("created_at > ?", period_start(period)).sum(:total)
    }

    MCP::Tool::Response.new([
      { type: "text", text: format_stats(stats) }
    ])
  end

  private

  def period_start(period)
    case period
    when "day" then 1.day.ago
    when "week" then 1.week.ago
    when "month" then 1.month.ago
    end
  end

  def format_stats(stats)
    <<~TEXT
      ## Business Metrics
      - New users: #{stats[:users]}
      - New orders: #{stats[:orders]}
      - Revenue: $#{stats[:revenue]}
    TEXT
  end
end
```

## Registering custom tools

Add your tool classes to the configuration:

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    config.custom_tools = [RailsGetBusinessMetrics]
  end
end
```

Custom tools appear alongside built-in tools in the MCP server and CLI.

## Using BaseTool features

For access to caching, pagination, and helper methods, you can use `RailsAiContext::Tools::BaseTool` utilities directly:

```ruby
class RailsGetDeployStatus < MCP::Tool
  tool_name "rails_get_deploy_status"
  description "Returns current deployment status"

  def call
    # Use SafeFile for safe reading
    version = RailsAiContext::SafeFile.read(Rails.root.join("REVISION"))
    deployed_at = File.mtime(Rails.root.join("tmp/restart.txt")) rescue nil

    MCP::Tool::Response.new([
      { type: "text", text: "Version: #{version&.strip}\nDeployed: #{deployed_at}" }
    ])
  end
end
```

## Naming conventions

- Prefix tool names with `rails_` per MCP best practices
- Use `rails_get_` for data retrieval tools
- Use `rails_` without `get_` for action tools (e.g., `rails_validate`)

## Testing custom tools

Use the built-in `TestHelper` module:

### With RSpec

```ruby
# spec/mcp_tools/rails_get_business_metrics_spec.rb
require "rails_helper"
require "rails_ai_context/test_helper"

RSpec.describe RailsGetBusinessMetrics do
  include RailsAiContext::TestHelper

  it "is registered as an MCP tool" do
    assert_tool_findable("rails_get_business_metrics")
  end

  it "returns metrics for the default period" do
    response = execute_tool("rails_get_business_metrics")
    assert_tool_response_includes(response, "Business Metrics")
  end

  it "accepts a period parameter" do
    response = execute_tool("rails_get_business_metrics", period: "month")
    assert_tool_response_includes(response, "Revenue")
  end

  it "does not expose sensitive data" do
    response = execute_tool("rails_get_business_metrics")
    assert_tool_response_excludes(response, "password")
  end
end
```

### With Minitest

```ruby
# test/mcp_tools/rails_get_business_metrics_test.rb
require "test_helper"
require "rails_ai_context/test_helper"

class RailsGetBusinessMetricsTest < ActiveSupport::TestCase
  include RailsAiContext::TestHelper

  test "is registered as an MCP tool" do
    assert_tool_findable("rails_get_business_metrics")
  end

  test "returns metrics" do
    response = execute_tool("rails_get_business_metrics")
    assert_tool_response_includes(response, "Business Metrics")
  end
end
```

## TestHelper API

| Method | Description |
|:-------|:------------|
| `execute_tool(name_or_class, **args)` | Execute a tool by name, short name, or class. Returns `MCP::Tool::Response`. |
| `execute_tool_with_error(name_or_class, **args)` | Execute a tool expecting an error response. |
| `assert_tool_findable(name_or_class)` | Assert the tool is registered and discoverable. |
| `assert_tool_response_includes(response, text)` | Assert response contains the given text. |
| `assert_tool_response_excludes(response, text)` | Assert response does NOT contain the given text. |
| `extract_response_text(response)` | Extract plain text from an `MCP::Tool::Response`. |

**Name resolution** is fuzzy — all of these resolve to the same tool:

```ruby
execute_tool("rails_get_schema")
execute_tool("get_schema")
execute_tool("schema")
execute_tool(RailsAiContext::Tools::GetSchema)
```

## Excluding built-in tools

If a custom tool replaces a built-in one, exclude the original:

```ruby
RailsAiContext.configure do |config|
  config.custom_tools = [MyBetterSecurityScan]
  config.skip_tools   = %w[rails_security_scan]
end
```

## Tips

- Custom tools have access to the full Rails environment — ActiveRecord, services, mailers, etc.
- Keep tools read-only when possible. MCP tools annotated as non-destructive build more trust with AI clients.
- Return `MCP::Tool::Response` objects with `type: "text"` content blocks.
- Tool responses are automatically truncated at `config.max_tool_response_chars` (default: 200,000).

---

<div align="center">

**[← Recipes](RECIPES.md)** · **[Configuration →](CONFIGURATION.md)**

[Back to README](../README.md)

</div>
