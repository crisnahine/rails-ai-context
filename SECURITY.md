# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 4.2.x   | :white_check_mark: (4.2.1 includes security hardening) |
| 4.1.x   | :white_check_mark: |
| 4.0.x   | :white_check_mark: |
| 3.1.x   | :white_check_mark: |
| 3.0.x   | :x:                |
| 2.0.x   | :x:                |
| < 2.0   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in rails-ai-context, please report it responsibly:

1. **Do NOT open a public GitHub issue.**
2. Email **crisjosephnahine@gmail.com** with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
3. You will receive a response within 48 hours.
4. A fix will be released as a patch version as soon as possible.

## Security Design

- All 37 MCP tools are **read-only** and never modify your application or database.
- **Sensitive file blocking** — configurable `sensitive_patterns` blocks access to `.env`, `*.key`, `*.pem`, `credentials.yml.enc` across all search and read tools. Patterns are checked in `rails_search_code`, `rails_get_edit_context`, and all new tools.
- **Path traversal protection** — all file-reading tools validate paths with `File.realpath()` against `Rails.root` to prevent directory escape.
- **Command injection prevention** — code search uses `Open3.capture2` with array arguments (never shell strings). The `--` flag separator prevents pattern injection.
- **Regex DoS protection** — user-supplied regex patterns have 1-2 second timeouts via `Regexp.new(pattern, timeout:)`.
- **Credential safety** — `rails_get_env` only reads `.env.example` (never `.env`), shows credential key names only (never values), and redacts secrets. `rails_get_config` exposes adapter/framework names, not connection strings.
- **Brakeman integration** — optional `rails_security_scan` tool runs static security analysis. Graceful degradation if not installed. Users can exclude it via `config.skip_tools = %w[rails_security_scan]`.
- **File size limits** — all tools enforce configurable `max_file_size` (default 5MB) to prevent memory exhaustion on large files.
- **SQL comment stripping** — `rails_query` strips block (`/* */`), line (`--`), and MySQL-style (`#`) comments before validation to prevent keyword hiding.
- **Regex interpolation safety** — all introspectors use `Regexp.escape` when interpolating model/association names into patterns to prevent regex injection.
- **Log redaction** — `rails_read_logs` redacts passwords, tokens, secrets, API keys, cookies, session IDs, emails, and environment variables before output.
- **Migration input validation** — `rails_migration_advisor` validates table and column names as safe identifiers before generating migration code.
- **Cache invalidation coverage** — Fingerprinter watches `app/components`, `package.json`, and `tsconfig.json` alongside models/controllers/views to prevent stale tool responses.
- **Fetch size limits** — `rails_search_docs` caps fetched documentation content at 2MB to prevent memory exhaustion.
- The gem makes outbound HTTPS requests only when `rails_search_docs` is called with `fetch: true` (to fetch Rails documentation from GitHub raw content). All other tools are offline.
