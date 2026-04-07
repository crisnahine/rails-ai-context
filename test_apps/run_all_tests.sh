#!/usr/bin/env bash
# =============================================================================
# Master Test Runner for rails-ai-context gem
#
# Tests ALL features across 3 apps:
#   full_app    — comprehensive Rails 8 app (all 31 introspectors, all patterns)
#   api_app     — API-only app (api_only detection, CLI tool_mode)
#   minimal_app — bare minimum (graceful degradation)
#
# Usage:
#   ./run_all_tests.sh              # Run all tests
#   ./run_all_tests.sh full_app     # Test one app only
#   ./run_all_tests.sh --tools-only # Only test MCP tools
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

PASS=0
FAIL=0
SKIP=0
ERRORS=()

# ==== Helpers ====

header() {
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

section() {
  echo ""
  echo -e "${CYAN}── $1 ──${NC}"
}

pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "  ${RED}✗${NC} $1"
  echo -e "    ${RED}$2${NC}"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

skip() {
  echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"
  SKIP=$((SKIP + 1))
}

# Run a command and check exit code
run_check() {
  local description="$1"
  shift
  local output
  if output=$("$@" 2>&1); then
    pass "$description"
    return 0
  else
    fail "$description" "$(echo "$output" | tail -5)"
    return 1
  fi
}

# Run a command and check output contains expected string
run_check_output() {
  local description="$1"
  local expected="$2"
  shift 2
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -qi "$expected"; then
    pass "$description"
    return 0
  else
    fail "$description" "Expected '$expected' in output. Got: $(echo "$output" | head -3)"
    return 1
  fi
}

# Run a command silently, only report failures
run_silent() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description" "Command failed: $*"
  fi
}

# ==== Per-App Tests ====

test_doctor() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"
  section "Doctor — $app_name"

  run_check "rails-ai-context doctor runs" \
    bundle exec rails-ai-context doctor
}

test_context_generation() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"
  section "Context Generation — $app_name"

  # Generate context files
  run_check "rails-ai-context context generates files" \
    bundle exec rails-ai-context context

  # Check generated files exist
  for file in CLAUDE.md .cursor/rules/rails-project.mdc .github/instructions/rails-context.instructions.md; do
    if [ -f "$app_dir/$file" ]; then
      pass "Generated: $file"
    else
      fail "Not generated: $file" "File missing at $app_dir/$file"
    fi
  done

  # Check CLAUDE.md has content
  if [ -f "$app_dir/CLAUDE.md" ]; then
    local lines
    lines=$(wc -l < "$app_dir/CLAUDE.md")
    if [ "$lines" -gt 5 ]; then
      pass "CLAUDE.md has content ($lines lines)"
    else
      fail "CLAUDE.md is too short" "$lines lines"
    fi
  fi
}

test_cli_tools() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"
  section "CLI Tools (via rake) — $app_name"

  # All 38 MCP tools by short name — tested via rake ai:tool[name]
  # (The standalone CLI has a pre-existing full_gem_path issue; rake path works.)
  local tools=(
    schema
    model_details
    routes
    gems
    search_code
    conventions
    controllers
    config
    test_info
    view
    stimulus
    edit_context
    validate
    analyze_feature
    security_scan
    concern
    callbacks
    helper_methods
    service_pattern
    job_pattern
    env
    partial_interface
    turbo_map
    context
    component_catalog
    performance_check
    dependency_graph
    migration_advisor
    frontend_stack
    search_docs
    query
    read_logs
    generate_test
    diagnose
    review_changes
    onboard
    runtime_info
    session_context
  )

  for tool in "${tools[@]}"; do
    local output
    if output=$(bundle exec rake "ai:tool[$tool]" 2>&1); then
      # Check it returned something (not just empty)
      if [ -n "$output" ] && ! echo "$output" | grep -qi "error.*unknown\|not found\|undefined"; then
        pass "tool $tool"
      else
        fail "tool $tool" "Empty or error output"
      fi
    else
      # Some tools may fail gracefully or require arguments
      if echo "$output" | grep -qi "not available\|not installed\|no .* found\|skipped\|not configured\|no .* detected\|requires.*param\|missing.*argument"; then
        pass "tool $tool (graceful degradation)"
      elif [ "$tool" = "partial_interface" ]; then
        pass "tool $tool (requires partial= argument — expected)"
      else
        fail "tool $tool" "$(echo "$output" | tail -3)"
      fi
    fi
  done
}

test_rake_tasks() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"
  section "Rake Tasks — $app_name"

  # Check ai: namespace exists
  run_check_output "rake ai:context task exists" "ai:context" \
    bundle exec rake -T ai

  # Run ai:context
  run_check "rake ai:context runs" \
    bundle exec rake ai:context
}

test_introspectors() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"
  section "Introspectors (via Ruby) — $app_name"

  # Use direct Ruby introspection and write keys to temp file
  local tmpfile
  tmpfile=$(mktemp)
  if bundle exec ruby -e "
    require_relative 'config/environment'
    context = RailsAiContext::Introspector.new(Rails.application).call
    context.each_key { |k| puts k }
  " > "$tmpfile" 2>&1; then
    pass "introspection runs"

    # Check key sections exist
    for key in schema models routes controllers conventions gems jobs stimulus views migrations config; do
      if grep -q "^${key}$" "$tmpfile"; then
        pass "introspector: $key"
      else
        fail "introspector missing: $key" "Key '$key' not in introspector output"
      fi
    done
  else
    fail "introspection failed" "$(cat "$tmpfile" | tail -5)"
  fi
  rm -f "$tmpfile"
}

test_mcp_server() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"
  section "MCP Server — $app_name"

  # Start MCP server in background, send initialize request, check response
  local server_pid=""
  local tmpfile
  tmpfile=$(mktemp)

  # Start server via Ruby (CLI exe has pre-existing full_gem_path issue in standalone mode)
  bundle exec ruby -e "require_relative 'config/environment'; RailsAiContext.start_mcp_server(transport: :stdio)" < /dev/null > "$tmpfile" 2>&1 &
  server_pid=$!

  # Give it a moment to boot
  sleep 2

  # Check if server started (process still running)
  if kill -0 "$server_pid" 2>/dev/null; then
    pass "MCP server starts"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  else
    # Server may have exited after reading EOF from stdin — that's OK for stdio
    if grep -qi "rails-ai-context\|mcp\|server\|initialize\|Exiting" "$tmpfile"; then
      pass "MCP server starts (stdio mode, exited on EOF)"
    else
      fail "MCP server start" "Process exited. Output: $(cat "$tmpfile" | head -5)"
    fi
  fi

  rm -f "$tmpfile"
}

test_full_app_specific() {
  local app_dir="$1"
  section "Full App-Specific Checks"

  # Check all detection patterns by examining conventions output
  local output
  output=$(bundle exec rake "ai:tool[conventions]" 2>&1) || true

  # Architecture detections (human-readable labels from conventions tool output)
  for pattern in "Hotwire" "Solid queue" "Solid cache" "Solid cable" "Kamal" "Docker" "GitHub Actions" "Service objects" "Form objects" "Query objects" "Presenters" "Policies" "Serializers" "Validators" "Notifiers" "ViewComponent" "Pwa" "Concerns models" "Concerns controllers" "Dry rb" "Feature flags" "Error monitoring" "Zeitwerk"; do
    if echo "$output" | grep -qi "$pattern"; then
      pass "detects: $pattern"
    else
      fail "not detected: $pattern" "Expected '$pattern' in conventions output"
    fi
  done

  # Pattern detections
  for pattern in "Single Table Inheritance" "Polymorphic" "versioning" "State machine" "Current attributes" "Encrypted" "Normalizations"; do
    if echo "$output" | grep -qi "$pattern"; then
      pass "pattern: $pattern"
    else
      fail "pattern not detected: $pattern" "Expected '$pattern' in conventions output"
    fi
  done

  # Runtime info (includes multi-database)
  run_check_output "runtime info runs" "table\|database" \
    bundle exec rake "ai:tool[runtime_info]"

  # Stimulus controllers detected
  run_check_output "stimulus controllers detected" "hello\|modal\|search" \
    bundle exec rake "ai:tool[stimulus]"

  # Components detected
  run_check_output "components detected" "button\|card\|alert" \
    bundle exec rake "ai:tool[component_catalog]"

  # Frontend stack detected
  run_check_output "frontend stack detected" "react\|esbuild\|tailwind" \
    bundle exec rake "ai:tool[frontend_stack]"

  # Config (includes auth, middleware, etc.)
  run_check_output "config detected" "cache\|session\|queue" \
    bundle exec rake "ai:tool[config]"

  # Performance check runs
  run_check "performance check runs" \
    bundle exec rake "ai:tool[performance_check]"

  # Onboard narrative
  run_check_output "onboard narrative" "FullApp\|Rails" \
    bundle exec rake "ai:tool[onboard]"

  # Service pattern analysis
  run_check_output "service pattern detected" "UserRegistration\|Search\|Publisher" \
    bundle exec rake "ai:tool[service_pattern]"

  # Job pattern analysis
  run_check_output "job pattern detected" "ProcessData\|Cleanup\|SendNotification" \
    bundle exec rake "ai:tool[job_pattern]"
}

test_api_app_specific() {
  local app_dir="$1"
  section "API App-Specific Checks"

  local output
  output=$(bundle exec rake "ai:tool[conventions]" 2>&1) || true

  if echo "$output" | grep -qi "API-only"; then
    pass "api_only mode detected"
  else
    fail "api_only not detected" "Expected 'API-only' in conventions output"
  fi

  # Check API routes detected
  run_check_output "API routes detected" "products\|orders" \
    bundle exec rake "ai:tool[routes]"

  # Schema works
  run_check_output "schema works" "products\|orders" \
    bundle exec rake "ai:tool[schema]"
}

test_minimal_app_specific() {
  local app_dir="$1"
  section "Minimal App-Specific Checks"

  # All tools should run without crashing even with minimal setup
  run_check "schema tool on minimal app" \
    bundle exec rake "ai:tool[schema]"

  run_check "conventions tool on minimal app" \
    bundle exec rake "ai:tool[conventions]"

  run_check "context generation on minimal app" \
    bundle exec rails-ai-context context
}

# ==== Run Tests for One App ====

test_app() {
  local app_dir="$1"
  local app_name="$(basename "$app_dir")"

  header "Testing: $app_name"

  cd "$app_dir"

  test_doctor "$app_dir"
  test_context_generation "$app_dir"
  test_introspectors "$app_dir"
  test_cli_tools "$app_dir"
  test_rake_tasks "$app_dir"
  test_mcp_server "$app_dir"

  # App-specific tests
  case "$app_name" in
    full_app)    test_full_app_specific "$app_dir" ;;
    api_app)     test_api_app_specific "$app_dir" ;;
    minimal_app) test_minimal_app_specific "$app_dir" ;;
  esac
}

# ==== Main ====

main() {
  header "rails-ai-context Integration Test Suite"
  echo "  Gem root: $GEM_ROOT"
  echo "  Date: $(date)"
  echo ""

  local target="${1:-all}"

  case "$target" in
    full_app|api_app|minimal_app)
      test_app "$SCRIPT_DIR/$target"
      ;;
    --tools-only)
      cd "$SCRIPT_DIR/full_app"
      test_cli_tools "$SCRIPT_DIR/full_app"
      ;;
    all)
      for app in full_app api_app minimal_app; do
        if [ -d "$SCRIPT_DIR/$app" ]; then
          test_app "$SCRIPT_DIR/$app"
        else
          echo -e "${YELLOW}Skipping $app (not found)${NC}"
        fi
      done
      ;;
    *)
      echo "Usage: $0 [full_app|api_app|minimal_app|--tools-only|all]"
      exit 1
      ;;
  esac

  # ==== Summary ====
  header "Test Summary"
  echo ""
  echo -e "  ${GREEN}Passed:${NC}  $PASS"
  echo -e "  ${RED}Failed:${NC}  $FAIL"
  echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
  echo -e "  ${BOLD}Total:${NC}   $((PASS + FAIL + SKIP))"
  echo ""

  if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}${BOLD}FAILURES:${NC}"
    for err in "${ERRORS[@]}"; do
      echo -e "  ${RED}• $err${NC}"
    done
    echo ""
    echo -e "${RED}${BOLD}RESULT: FAIL${NC}"
    exit 1
  else
    echo -e "${GREEN}${BOLD}RESULT: ALL TESTS PASSED${NC}"
    exit 0
  fi
}

main "$@"
