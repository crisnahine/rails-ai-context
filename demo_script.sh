#!/bin/bash
# Simulated demo output for VHS recording
clear

printf '\033[1;36m$\033[0m bundle add rails-ai-context\n'
sleep 0.3
echo 'Fetching gem metadata from https://rubygems.org...'
sleep 0.3
echo 'Resolving dependencies...'
sleep 0.3
echo 'Installing rails-ai-context 0.12.0'
echo ''
sleep 1

printf '\033[1;36m$\033[0m rails ai:doctor\n'
echo ''
sleep 0.2
echo '  ✅ Schema        db/schema.rb found (14 tables)'
sleep 0.15
echo '  ✅ Models        12 model files detected'
sleep 0.15
echo '  ✅ Routes        48 routes mapped'
sleep 0.15
echo '  ✅ Controllers   8 controllers with actions'
sleep 0.15
echo '  ✅ Gems          6 notable gems recognized'
sleep 0.15
echo '  ✅ Tests         RSpec with 142 examples'
sleep 0.15
echo '  ✅ Views         34 templates, 12 partials'
sleep 0.15
echo '  ⚠️  I18n         Only 1 locale (en)'
sleep 0.15
echo '  ✅ Config        Cache: redis, Sessions: cookie'
sleep 0.15
echo '  ✅ MCP Server    Ready (stdio transport)'
sleep 0.15
echo '  ✅ Ripgrep       Installed (fast code search)'
sleep 0.15
echo '  ✅ Live reload   `listen` gem available'
echo ''
sleep 0.3
printf '  \033[1;32mAI Readiness Score: 92/100\033[0m\n'
echo ''
sleep 1

printf '\033[1;36m$\033[0m rails ai:context\n'
echo ''
sleep 0.2
echo '  ✅ CLAUDE.md'
sleep 0.08
echo '  ✅ .claude/rules/rails-schema.md'
sleep 0.08
echo '  ✅ .claude/rules/rails-models.md'
sleep 0.08
echo '  ✅ .claude/rules/rails-mcp-tools.md'
sleep 0.08
echo '  ✅ AGENTS.md'
sleep 0.08
echo '  ✅ app/models/AGENTS.md'
sleep 0.08
echo '  ✅ app/controllers/AGENTS.md'
sleep 0.08
echo '  ✅ .cursor/rules/rails-project.mdc'
sleep 0.08
echo '  ✅ .cursor/rules/rails-project.mdc'
sleep 0.08
echo '  ✅ .cursor/rules/rails-models.mdc'
sleep 0.08
echo '  ✅ .cursor/rules/rails-controllers.mdc'
sleep 0.08
echo '  ✅ .cursor/rules/rails-mcp-tools.mdc'
sleep 0.08
echo '  ✅ .windsurfrules'
sleep 0.08
echo '  ✅ .windsurf/rules/rails-context.md'
sleep 0.08
echo '  ✅ .windsurf/rules/rails-mcp-tools.md'
sleep 0.08
echo '  ✅ .github/copilot-instructions.md'
sleep 0.08
echo '  ✅ .github/instructions/rails-models.instructions.md'
sleep 0.08
echo '  ✅ .github/instructions/rails-controllers.instructions.md'
sleep 0.08
echo '  ✅ .github/instructions/rails-mcp-tools.instructions.md'
sleep 0.08
echo '  ✅ .ai-context.json'
echo ''
sleep 0.3
printf '  \033[1;32mDone! Your AI assistants now understand your Rails app.\033[0m\n'
printf '  \033[0;90mCommit these files so your whole team benefits.\033[0m\n'
sleep 2
