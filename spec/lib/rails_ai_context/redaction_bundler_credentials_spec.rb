# frozen_string_literal: true

require "spec_helper"

# Every form below is one input, the file kind it sits in, and what must come out: the credential gone and the code
# around it kept. The credential is the fake pair usr7k:Pw9T4il.
module BundlerCredentialRows
  SECRET_PARTS = %w[usr7k Pw9 T4il].freeze

  ROWS = [
      [ "C01-dq-control", "Dockerfile", "RUN bundle config --global gems.example.com \"usr7k:Pw9T4il\"",
        "RUN bundle config --global gems.example.com \"[FILTERED]\"" ],
      [ "C02-sq-space", "Dockerfile", "RUN bundle config set --global gems.example.com 'usr7k:Pw9 T4il'",
        "RUN bundle config set --global gems.example.com '[FILTERED]'" ],
      [ "C03-dq-then-andand-spaced", "Dockerfile", "RUN bundle config set gems.example.com \"usr7k:Pw9 T4il\" && bundle install",
        "RUN bundle config set gems.example.com \"[FILTERED]\" && bundle install" ],
      [ "C04-dq-then-andand-nospace", "Dockerfile", "RUN bundle config set gems.example.com \"usr7k:Pw9T4il\"&& bundle install",
        "RUN bundle config set gems.example.com \"[FILTERED]\"&& bundle install" ],
      [ "C05-dq-continuation-spaced", "Dockerfile", "RUN bundle config set gems.example.com \"usr7k:Pw9T4il\" \\",
        "RUN bundle config set gems.example.com \"[FILTERED]\" \\" ],
      [ "C06-dq-continuation-nospace", "Dockerfile", "RUN bundle config set gems.example.com \"usr7k:Pw9T4il\"\\",
        "RUN bundle config set gems.example.com \"[FILTERED]\"\\" ],
      [ "C07-sh-c-single-wrapping-double", "Dockerfile", "RUN sh -c 'bundle config set gems.example.com \"usr7k:Pw9T4il\"'",
        "RUN sh -c 'bundle config set gems.example.com \"[FILTERED]\"'" ],
      [ "C08-exec-form", "Dockerfile", "RUN [\"bundle\", \"config\", \"set\", \"gems.example.com\", \"usr7k:Pw9T4il\"]",
        "RUN [\"bundle\", \"config\", \"set\", \"gems.example.com\", \"[FILTERED]\"]" ],
      [ "C09-ansi-c-quote", "Dockerfile", "RUN bundle config set gems.example.com $'usr7k:Pw9\\'T4il'",
        "RUN bundle config set gems.example.com $'[FILTERED]'" ],
      [ "C10-adjacent-dq-sq", "Dockerfile", "RUN bundle config set gems.example.com \"usr7k:\"'Pw9T4il'",
        "RUN bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C11-adjacent-sq-dq", "Dockerfile", "RUN bundle config set gems.example.com 'usr7k:'\"Pw9T4il\"",
        "RUN bundle config set gems.example.com '[FILTERED]'" ],
      [ "C12-adjacent-dq-bare", "Dockerfile", "RUN bundle config set gems.example.com \"usr7k:\"Pw9T4il",
        "RUN bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C13-adjacent-bare-dq", "Dockerfile", "RUN bundle config set gems.example.com usr7k:\"Pw9 T4il\"",
        "RUN bundle config set gems.example.com [FILTERED]" ],
      [ "C14-gha-run-dq-space", ".github/workflows/ci.yml", "      run: bundle config set gems.example.com \"usr7k:Pw9 T4il\"",
        "      run: bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C15-gha-run-sq-wrapping-dq", ".github/workflows/ci.yml", "      run: 'bundle config set gems.example.com \"usr7k:Pw9T4il\"'",
        "      run: 'bundle config set gems.example.com \"[FILTERED]\"'" ],
      [ "C16-gha-run-dq-wrapping-sq", ".github/workflows/ci.yml", "      run: \"bundle config set gems.example.com 'usr7k:Pw9T4il'\"",
        "      run: \"bundle config set gems.example.com '[FILTERED]'\"" ],
      [ "C17-gha-run-block", ".github/workflows/ci.yml", "      run: |\n        bundle config set gems.example.com \"usr7k:Pw9 T4il\"\n        bundle install",
        "      run: |\n        bundle config set gems.example.com \"[FILTERED]\"\n        bundle install" ],
      [ "C18-gitlab-dq-semicolon", ".gitlab-ci.yml", "  - bundle config set --local gems.example.com \"usr7k:Pw9;T4il\"",
        "  - bundle config set --local gems.example.com \"[FILTERED]\"" ],
      [ "C19-gitlab-sq-wrapping-dq", ".gitlab-ci.yml", "  - 'bundle config set gems.example.com \"usr7k:Pw9T4il\"'",
        "  - 'bundle config set gems.example.com \"[FILTERED]\"'" ],
      [ "C20-dq-escaped-quote", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9\\\"T4il\"",
        "bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C21-sq-close-escape-reopen", "bin/setup", "bundle config set gems.example.com 'usr7k:Pw9'\\''T4il'",
        "bundle config set gems.example.com '[FILTERED]'" ],
      [ "C22-sq-close-escape-reopen-space", "bin/setup", "bundle config set gems.example.com 'usr7k:Pw9'\\'' T4il'",
        "bundle config set gems.example.com '[FILTERED]'" ],
      [ "C23-dq-hash", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9#T4il\"",
        "bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C24-dq-eq-at", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9=T4il@x\"",
        "bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C25-dq-unicode", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9ñ€T4il\"",
        "bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "C26-ruby-system-sq-wrapping-dq", "lib/tasks/setup.rake", "system('bundle config set gems.example.com \"usr7k:Pw9T4il\"')",
        "system('bundle config set gems.example.com \"[FILTERED]\"')" ],
      [ "C27-ruby-sh-dq-wrapping-sq", "lib/tasks/setup.rake", "sh \"bundle config set gems.example.com 'usr7k:Pw9T4il'\"",
        "sh \"bundle config set gems.example.com '[FILTERED]'\"" ],
      [ "C28-ruby-escaped-dq-inside-dq", "lib/tasks/setup.rake", "system(\"bundle config set gems.example.com \\\"usr7k:Pw9T4il\\\"\")",
        "system(\"bundle config set gems.example.com \\\"[FILTERED]\\\"\")" ],
      [ "C29-markdown-inline-code", "README.md", "Run `bundle config set --global gems.example.com \"usr7k:Pw9T4il\"` once.",
        "Run `bundle config set --global gems.example.com \"[FILTERED]\"` once." ],
      [ "C31-json-script-sq", "app.json", "    \"postdeploy\": \"bundle config set gems.example.com 'usr7k:Pw9T4il'\",",
        "    \"postdeploy\": \"bundle config set gems.example.com '[FILTERED]'\"," ],
      [ "C32-dq-unclosed-eol", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9 T4il",
        "bundle config set gems.example.com \"[FILTERED]" ],
      [ "C33-sq-unclosed-eol", "bin/setup", "bundle config set gems.example.com 'usr7k:Pw9 T4il",
        "bundle config set gems.example.com '[FILTERED]" ],
      [ "C34-old-syntax-no-set", "bin/setup", "bundle config gems.example.com \"usr7k:Pw9 T4il\"",
        "bundle config gems.example.com \"[FILTERED]\"" ],
      [ "C35-url-key", "bin/setup", "bundle config set --global https://gems.example.com/ \"usr7k:Pw9T4il\"",
        "bundle config set --global https://gems.example.com/ \"[FILTERED]\"" ],
      [ "C36-dq-pipe-nospace", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9T4il\"|| true",
        "bundle config set gems.example.com \"[FILTERED]\"|| true" ],
      [ "C37-dq-redirect-nospace", "bin/setup", "bundle config set gems.example.com \"usr7k:Pw9T4il\">/dev/null",
        "bundle config set gems.example.com \"[FILTERED]\">/dev/null" ],
      [ "C38-sq-yaml-dq-inside", "bin/setup", "bundle config set gems.example.com 'usr7k:Pw9\" T4il'",
        "bundle config set gems.example.com '[FILTERED]'" ],
      [ "A01-env-dq-space", "Dockerfile", "ENV BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"",
        "ENV BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A02-env-sq-space", "Dockerfile", "ENV BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9 T4il'",
        "ENV BUNDLE_GEMS__EXAMPLE__COM='[FILTERED]'" ],
      [ "A03-env-dq-then-other", "Dockerfile", "ENV BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9T4il\" OTHER=1",
        "ENV BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\" OTHER=1" ],
      [ "A04-arg-dq-comma", "Dockerfile", "ARG BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9,T4il\"",
        "ARG BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A05-env-legacy-dq-space", "Dockerfile", "ENV BUNDLE_GEMS__EXAMPLE__COM \"usr7k:Pw9 T4il\"",
        "ENV BUNDLE_GEMS__EXAMPLE__COM \"[FILTERED]\"" ],
      [ "A06-env-backslash-space", "Dockerfile", "ENV BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9\\ T4il",
        "ENV BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "A07-run-prefix-dq", "Dockerfile", "RUN BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\" bundle install",
        "RUN BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\" bundle install" ],
      [ "A08-echo-sq-wrapping-dq-space", "Dockerfile", "RUN echo 'BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9 T4il\"' >> .bundle/config",
        "RUN echo 'BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"' >> .bundle/config" ],
      [ "A10-compose-map-dq-space", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9 T4il\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"" ],
      [ "A11-compose-map-sq-space", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9 T4il'",
        "      BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]'" ],
      [ "A12-compose-map-plain-space", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9 T4il",
        "      BUNDLE_GEMS__EXAMPLE__COM: [FILTERED]" ],
      [ "A13-compose-list-bare-space", "docker-compose.yml", "      - BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il",
        "      - BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "A14-compose-list-dq-whole-space", "docker-compose.yml", "      - \"BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il\"",
        "      - \"BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]\"" ],
      [ "A15-compose-list-sq-whole-comma", "docker-compose.yml", "      - 'BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9,T4il'",
        "      - 'BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]'" ],
      [ "A16-yaml-sq-doubled-then-space", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9'' T4il'",
        "      BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]'" ],
      [ "A17-yaml-sq-doubled-then-dot", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9''.T4il'",
        "      BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]'" ],
      [ "A18-yaml-sq-doubled-then-comma", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9'',T4il'",
        "      BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]'" ],
      [ "A19-yaml-dq-escaped-then-space", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9\\\" T4il\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"" ],
      [ "A20-yaml-block-folded", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: >-\n        usr7k:Pw9T4il",
        "      BUNDLE_GEMS__EXAMPLE__COM: >-\n        [FILTERED]" ],
      [ "A21-yaml-dq-multiline", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9\n        T4il\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\n        [FILTERED]\"" ],
      [ "A22-yaml-flow-map", "docker-compose.yml", "    environment: { BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9 T4il\", X: 1 }",
        "    environment: { BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\", X: 1 }" ],
      [ "A23-yaml-plain-comment", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il # creds",
        "      BUNDLE_GEMS__EXAMPLE__COM: [FILTERED] # creds" ],
      [ "A24-yaml-dq-comment-quote", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9 T4il\" # creds \"z\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\" # creds \"z\"" ],
      [ "A25-yaml-sq-trailing-doubled-end", "docker-compose.yml", "      BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9T4il'''",
        "      BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]'" ],
      [ "A30-gha-env-dq", ".github/workflows/ci.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9 T4il\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"" ],
      [ "A31-gha-echo-github-env", ".github/workflows/ci.yml", "        run: echo \"BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il\" >> $GITHUB_ENV",
        "        run: echo \"BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]\" >> $GITHUB_ENV" ],
      [ "A32-gitlab-var-sq-paren", ".gitlab-ci.yml", "    BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9)T4il'",
        "    BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]'" ],
      [ "A33-gitlab-script-export-dq", ".gitlab-ci.yml", "    - export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"",
        "    - export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A40-bundler-inspect-escaped-dq", ".bundle/config", "BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9\\\"T4il\"",
        "BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"" ],
      [ "A41-bundler-inspect-escaped-backslash", ".bundle/config", "BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9\\\\T4il\"",
        "BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"" ],
      [ "A42-bundler-trailing-backslash", ".bundle/config", "BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\\\\\"",
        "BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"" ],
      [ "A43-url-key", ".bundle/config", "BUNDLE_HTTPS://GEMS__EXAMPLE__COM/: \"usr7k:Pw9T4il\"",
        "BUNDLE_HTTPS://GEMS__EXAMPLE__COM/: \"[FILTERED]\"" ],
      [ "A44-github-com-host", ".bundle/config", "BUNDLE_GITHUB__COM: \"usr7k:Pw9T4il\"",
        "BUNDLE_GITHUB__COM: \"[FILTERED]\"" ],
      [ "A50-dotenv-unquoted-space", ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il",
        "BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "A51-dotenv-dq-space", ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"",
        "BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A52-dotenv-sq-space", ".env.example", "BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9 T4il'",
        "BUNDLE_GEMS__EXAMPLE__COM='[FILTERED]'" ],
      [ "A53-dotenv-backtick", ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=`usr7k:Pw9T4il`",
        "BUNDLE_GEMS__EXAMPLE__COM=`[FILTERED]`" ],
      [ "A54-dotenv-colon", ".env.example", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il",
        "BUNDLE_GEMS__EXAMPLE__COM: [FILTERED]" ],
      [ "A55-dotenv-export-dq", ".env.example", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A60-ruby-index-dq-space", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:Pw9 T4il\"",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"" ],
      [ "A61-ruby-index-sq-space", "config/boot.rb", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = 'usr7k:Pw9 T4il'",
        "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = '[FILTERED]'" ],
      [ "A62-ruby-or-assign", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] ||= \"usr7k:Pw9T4il\"",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] ||= \"[FILTERED]\"" ],
      [ "A63-ruby-env-store", "config/boot.rb", "ENV.store(\"BUNDLE_GEMS__EXAMPLE__COM\", \"usr7k:Pw9T4il\")",
        "ENV.store(\"BUNDLE_GEMS__EXAMPLE__COM\", \"[FILTERED]\")" ],
      [ "A64-ruby-env-fetch-default", "config/boot.rb", "ENV.fetch(\"BUNDLE_GEMS__EXAMPLE__COM\", \"usr7k:Pw9T4il\")",
        "ENV.fetch(\"BUNDLE_GEMS__EXAMPLE__COM\", \"[FILTERED]\")" ],
      [ "A65-ruby-env-update-hash", "config/boot.rb", "ENV.update(\"BUNDLE_GEMS__EXAMPLE__COM\" => \"usr7k:Pw9 T4il\")",
        "ENV.update(\"BUNDLE_GEMS__EXAMPLE__COM\" => \"[FILTERED]\")" ],
      [ "A66-ruby-hash-sym", "config/boot.rb", "{ BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9 T4il\" }",
        "{ BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\" }" ],
      [ "A67-ruby-concat-plus", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:\" + \"Pw9T4il\"",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"" ],
      [ "A68-ruby-adjacent-literals", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:\" \"Pw9T4il\"",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"" ],
      [ "A69-ruby-percent-q", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = %q(usr7k:Pw9 T4il)",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = %q([FILTERED])" ],
      [ "A70-ruby-heredoc", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = <<~CREDS.strip\n  usr7k:Pw9T4il\nCREDS",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = <<~CREDS.strip\n  [FILTERED]\nCREDS" ],
      [ "A71-ruby-sq-escaped-then-space", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = 'usr7k:Pw9\\' T4il'",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = '[FILTERED]'" ],
      [ "A72-ruby-freeze", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:Pw9 T4il\".freeze",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\".freeze" ],
      [ "A73-ruby-modifier-if", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:Pw9 T4il\" if Rails.env.production?",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\" if Rails.env.production?" ],
      [ "A74-ruby-system-env-hash", "config/boot.rb", "system({ \"BUNDLE_GEMS__EXAMPLE__COM\" => \"usr7k:Pw9 T4il\" }, \"bundle install\")",
        "system({ \"BUNDLE_GEMS__EXAMPLE__COM\" => \"[FILTERED]\" }, \"bundle install\")" ],
      [ "A80-sh-export-dq-space", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A81-sh-ansi-c", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=$'usr7k:Pw9 T4il'",
        "export BUNDLE_GEMS__EXAMPLE__COM=$'[FILTERED]'" ],
      [ "A82-sh-backslash-space", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9\\ T4il",
        "export BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "A83-sh-dq-then-bare", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9\"T4il",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A84-sh-dq-then-sq", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9\"'T4il'",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A85-sh-sq-then-dq", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9'\"T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM='[FILTERED]'" ],
      [ "A86-sh-dq-dq-space", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9\"\" T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A87-sh-sq-escape-space", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9'\\'' T4il'",
        "export BUNDLE_GEMS__EXAMPLE__COM='[FILTERED]'" ],
      [ "A88-sh-dq-unclosed", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]" ],
      [ "A89-sh-dq-oror-space-inside", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"||true",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"||true" ],
      [ "A90-sh-env-cmd", "bin/setup", "env BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\" bundle install",
        "env BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\" bundle install" ],
      [ "A91-sh-bare-then-dq", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=usr7k:\"Pw9 T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "A92-sh-dq-then-sq-space", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:\"'Pw9 T4il'",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A93-sh-sq-then-dq-space", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM='usr7k:'\"Pw9 T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM='[FILTERED]'" ],
      [ "A94-sh-locale-dq", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=$\"usr7k:Pw9 T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=$\"[FILTERED]\"" ],
      [ "A95-sh-dq-escaped-dollar-backtick", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9\\`T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "A96-powershell", "script/deploy.ps1", "$env:BUNDLE_GEMS__EXAMPLE__COM = \"usr7k:Pw9 T4il\"",
        "$env:BUNDLE_GEMS__EXAMPLE__COM = \"[FILTERED]\"" ],
      [ "A97-cmd-set", "bin/setup.cmd", "set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il",
        "set BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "A98-fish-set", "bin/setup", "set -x BUNDLE_GEMS__EXAMPLE__COM \"usr7k:Pw9T4il\"",
        "set -x BUNDLE_GEMS__EXAMPLE__COM \"[FILTERED]\"" ],
      [ "A99-js-template-literal", "app/javascript/env.js", "const env = { BUNDLE_GEMS__EXAMPLE__COM: `usr7k:Pw9T4il` };",
        "const env = { BUNDLE_GEMS__EXAMPLE__COM: `[FILTERED]` };" ],
      [ "swallow-1", "bin/setup", "export BUNDLE_PATH=\"vendor\"&&export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9T4il\"",
        "export BUNDLE_PATH=\"vendor\"&&export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "swallow-2", "bin/setup", "export BUNDLE_PATH=\"vendor\"&&export BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il",
        "export BUNDLE_PATH=\"vendor\"&&export BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "swallow-3", "bin/setup", "BUNDLE_JOBS=\"4\"|BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9T4il\"",
        "BUNDLE_JOBS=\"4\"|BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "swallow-4", "Dockerfile", "RUN bundle config set build.nokogiri \"--x\"&&bundle config set gems.example.com \"usr7k:Pw9T4il\"",
        "RUN bundle config set build.nokogiri \"--x\"&&bundle config set gems.example.com \"[FILTERED]\"" ],
      [ "swallow-5", "Dockerfile", "RUN bundle config set build.nokogiri \"--x\"&&bundle config set gems.example.com usr7k:Pw9T4il",
        "RUN bundle config set build.nokogiri \"--x\"&&bundle config set gems.example.com [FILTERED]" ],
      [ "swallow-6", "config/boot.rb", "ENV[\"BUNDLE_PATH\"] = \"vendor\"if x; ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:Pw9T4il\"",
        "ENV[\"BUNDLE_PATH\"] = \"vendor\"if x; ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"" ],
      [ "swallow-7", "app.json", "\"env\": \"{\\\"BUNDLE_GEMS__EXAMPLE__COM\\\":\\\"usr7k:Pw9T4il\\\"}\"",
        "\"env\": \"{\\\"BUNDLE_GEMS__EXAMPLE__COM\\\":\\\"[FILTERED]\\\"}\"" ],
      [ "swallow-8", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:Pw9T4il\"if ENV[\"CI\"]",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"if ENV[\"CI\"]" ],
      [ "swallow2-1", "bin/setup", "export BUNDLE_JOBS=4;export BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il",
        "export BUNDLE_JOBS=4;export BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "swallow2-2", "bin/setup", "BUNDLE_JOBS=4;BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il bundle install",
        "BUNDLE_JOBS=4;BUNDLE_GEMS__EXAMPLE__COM=[FILTERED] bundle install" ],
      [ "swallow2-3", "config/ci.yml", "variables: {BUNDLE_JOBS: 4,BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il}",
        "variables: {BUNDLE_JOBS: 4,BUNDLE_GEMS__EXAMPLE__COM: [FILTERED]}" ],
      [ "swallow2-4", "config/boot.rb", "system({BUNDLE_JOBS: \"4\",BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\"}, \"bundle install\")",
        "system({BUNDLE_JOBS: \"4\",BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"}, \"bundle install\")" ],
      [ "swallow2-5", "config/boot.rb", "opts = {BUNDLE_JOBS: 4,BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\"}",
        "opts = {BUNDLE_JOBS: 4,BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"}" ],
      [ "swallow2-6", "config/boot.rb", "env(BUNDLE_PATH: path,BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\")",
        "env(BUNDLE_PATH: path,BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\")" ],
      [ "swallow2-7", "bin/setup", "BUNDLE_WITHOUT=test;BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9T4il\" bundle install",
        "BUNDLE_WITHOUT=test;BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\" bundle install" ],
      [ "esc-1", "lib/tasks/env.rake", "File.write(\".env\", \"BUNDLE_GEMS__EXAMPLE__COM=\\\"usr7k:Pw9T4il\\\"\\n\")",
        "File.write(\".env\", \"BUNDLE_GEMS__EXAMPLE__COM=\\\"[FILTERED]\\\"\\n\")" ],
      [ "esc-2", "lib/tasks/env.rake", "system(\"export BUNDLE_GEMS__EXAMPLE__COM=\\\"usr7k:Pw9 T4il\\\" && bundle install\")",
        "system(\"export BUNDLE_GEMS__EXAMPLE__COM=\\\"[FILTERED]\\\" && bundle install\")" ],
      [ "esc-3", "Dockerfile", "RUN echo \"BUNDLE_GEMS__EXAMPLE__COM: \\\"usr7k:Pw9T4il\\\"\" >> /usr/local/bundle/config",
        "RUN echo \"BUNDLE_GEMS__EXAMPLE__COM: \\\"[FILTERED]\\\"\" >> /usr/local/bundle/config" ],
      [ "esc-4", "Dockerfile", "RUN printf 'BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\"\\n' > .bundle/config",
        "RUN printf 'BUNDLE_GEMS__EXAMPLE__COM: \"[FILTERED]\"\\n' > .bundle/config" ],
      [ "named-1", ".gitlab-ci.yml", "variables:\n  BUNDLE_GEMS__EXAMPLE__COM:\n    value: \"usr7k:Pw9T4il\"\n    description: gem creds",
        "variables:\n  BUNDLE_GEMS__EXAMPLE__COM:\n    value: \"[FILTERED]\"\n    description: gem creds" ],
      [ "named-2", "config/deploy/k8s.yml", "env:\n  - name: BUNDLE_GEMS__EXAMPLE__COM\n    value: \"usr7k:Pw9T4il\"",
        "env:\n  - name: BUNDLE_GEMS__EXAMPLE__COM\n    value: \"[FILTERED]\"" ],
      [ "named-3", "app.json", "  \"env\": {\n    \"BUNDLE_GEMS__EXAMPLE__COM\": { \"value\": \"usr7k:Pw9T4il\" }\n  }",
        "  \"env\": {\n    \"BUNDLE_GEMS__EXAMPLE__COM\": { \"value\": \"[FILTERED]\" }\n  }" ],
      [ "named-4", "config/x.yml", "BUNDLE_GEMS__EXAMPLE__COM: { value: \"usr7k:Pw9T4il\" }",
        "BUNDLE_GEMS__EXAMPLE__COM: { value: \"[FILTERED]\" }" ],
      [ "named-5", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9#T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "named-6", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9#T4il",
        "export BUNDLE_GEMS__EXAMPLE__COM=[FILTERED]" ],
      [ "named-7", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k@Pw9=T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "named-8", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9ñ T4il'",
        "export BUNDLE_GEMS__EXAMPLE__COM='[FILTERED]'" ],
      [ "named-9", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"" ],
      [ "O01-path-bare", "Dockerfile", "RUN bundle config set --local path vendor/bundle",
        "RUN bundle config set --local path vendor/bundle" ],
      [ "O02-path-dq", "Dockerfile", "RUN bundle config set --local path \"vendor/bundle\"",
        "RUN bundle config set --local path \"vendor/bundle\"" ],
      [ "O03-without-dq-space", "bin/setup", "bundle config set without \"development test\"",
        "bundle config set without \"development test\"" ],
      [ "O04-without-sq-colon", "bin/setup", "bundle config set --local without 'development:test'",
        "bundle config set --local without 'development:test'" ],
      [ "O05-build-flags-dq", "Dockerfile", "RUN bundle config set --local build.nokogiri \"--use-system-libraries --with-xml2-config=/usr/bin/xml2-config\"",
        "RUN bundle config set --local build.nokogiri \"--use-system-libraries --with-xml2-config=/usr/bin/xml2-config\"" ],
      [ "O06-mirror-dq", "bin/setup", "bundle config set --global mirror.https://rubygems.org \"https://mirror.example.com\"",
        "bundle config set --global mirror.https://rubygems.org \"https://mirror.example.com\"" ],
      [ "O07-local-dq", "bin/setup", "bundle config set local.rack \"~/Work/rack\"",
        "bundle config set local.rack \"~/Work/rack\"" ],
      [ "O08-github-https-dq", "bin/setup", "bundle config set github.https \"true\"",
        "bundle config set github.https \"true\"" ],
      [ "O09-gem-test-dq", "bin/setup", "bundle config set gem.test \"rspec\"",
        "bundle config set gem.test \"rspec\"" ],
      [ "O10-host-placeholder-braces", "bin/setup", "bundle config set gems.example.com \"${GEM_CREDS}\"",
        "bundle config set gems.example.com \"${GEM_CREDS}\"" ],
      [ "O11-host-plain-var", "bin/setup", "bundle config set gems.example.com \"$GEM_CREDS\"",
        "bundle config set gems.example.com \"$GEM_CREDS\"" ],
      [ "O12-host-command-subst", "Dockerfile", "RUN --mount=type=secret,id=gem_creds bundle config set gems.example.com \"$(cat /run/secrets/gem_creds)\"",
        "RUN --mount=type=secret,id=gem_creds bundle config set gems.example.com \"$(cat /run/secrets/gem_creds)\"" ],
      [ "O13-jobs", "docker-compose.yml", "      BUNDLE_JOBS: \"4\"",
        "      BUNDLE_JOBS: \"4\"" ],
      [ "O14-path", "docker-compose.yml", "      BUNDLE_PATH: \"vendor/bundle\"",
        "      BUNDLE_PATH: \"vendor/bundle\"" ],
      [ "O15-without", "docker-compose.yml", "      BUNDLE_WITHOUT: \"development:test\"",
        "      BUNDLE_WITHOUT: \"development:test\"" ],
      [ "O16-build", "docker-compose.yml", "      BUNDLE_BUILD__NOKOGIRI: \"--use-system-libraries\"",
        "      BUNDLE_BUILD__NOKOGIRI: \"--use-system-libraries\"" ],
      [ "O17-gem-test", "docker-compose.yml", "      BUNDLE_GEM__TEST: 'rspec'",
        "      BUNDLE_GEM__TEST: 'rspec'" ],
      [ "O18-gemfile", "config/boot.rb", "ENV[\"BUNDLE_GEMFILE\"] ||= File.expand_path(\"../Gemfile\", __dir__)",
        "ENV[\"BUNDLE_GEMFILE\"] ||= File.expand_path(\"../Gemfile\", __dir__)" ],
      [ "O21-placeholder-your", "README.md", "BUNDLE_GEMS__CONTRIBSYS__COM: \"your-key-here\"",
        "BUNDLE_GEMS__CONTRIBSYS__COM: \"your-key-here\"" ],
      [ "O22-env-fetch", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = ENV.fetch(\"GEM_CREDS\")",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = ENV.fetch(\"GEM_CREDS\")" ],
      [ "O23-env-index", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = ENV[\"GEM_CREDS\"]",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = ENV[\"GEM_CREDS\"]" ],
      [ "O24-comparison", "config/boot.rb", "return if ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] == \"x\"",
        "return if ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] == \"x\"" ],
      [ "O25-no-space-modifier", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"u:p\"if ENV[\"CI\"]",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"if ENV[\"CI\"]" ],
      [ "O26-andand-then-echo", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"u:p\"&&echo \"configured\"",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\"&&echo \"configured\"" ],
      [ "O27-gha-expression", ".github/workflows/ci.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"${{ secrets.GEMS }}\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"${{ secrets.GEMS }}\"" ],
      [ "O28-jinja", "ansible/vars.yml", "      BUNDLE_GEMS__EXAMPLE__COM: \"{{ gem_creds }}\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"{{ gem_creds }}\"" ],
      [ "O29-erb", "config/x.yml.erb", "      BUNDLE_GEMS__EXAMPLE__COM: \"<%= ENV['GEM_CREDS'] %>\"",
        "      BUNDLE_GEMS__EXAMPLE__COM: \"<%= ENV['GEM_CREDS'] %>\"" ],
      [ "O30-symbol", "config/boot.rb", "{ BUNDLE_GEMS__EXAMPLE__COM: :from_env }",
        "{ BUNDLE_GEMS__EXAMPLE__COM: :from_env }" ],
      [ "O31-user-pass-vars", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"$USER:$PASS\"",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"$USER:$PASS\"" ],
      [ "O32-sq-doubled-nonsecret-setting", "docker-compose.yml", "      BUNDLE_WITHOUT: 'development''test'",
        "      BUNDLE_WITHOUT: 'development''test'" ],
      [ "github-https-flag", "bin/setup", "export BUNDLE_GITHUB__HTTPS=1",
        "export BUNDLE_GITHUB__HTTPS=1" ],
      [ "port-config", "bin/setup", "bundle config set gems.example.com:8080 \"usr7k:Pw9 T4il\"",
        "bundle config set gems.example.com:8080 \"[FILTERED]\"" ],
      [ "port-url-config", "bin/setup", "bundle config set --global https://gems.example.com:8080/ 'usr7k:Pw9 T4il'",
        "bundle config set --global https://gems.example.com:8080/ '[FILTERED]'" ],
      [ "port-key", ".bundle/config", "BUNDLE_GEMS__EXAMPLE__COM:8080: \"usr7k:Pw9 T4il\"",
        "BUNDLE_GEMS__EXAMPLE__COM:8080: \"[FILTERED]\"" ],
      [ "port-key-bare-host", ".bundle/config", "BUNDLE_LOCALHOST:9292: usr7k:Pw9 T4il",
        "BUNDLE_LOCALHOST:9292: [FILTERED]" ],
      [ "port-url-key", ".bundle/config", "BUNDLE_HTTPS://GEMS__EXAMPLE__COM:8080/: usr7k:Pw9 T4il",
        "BUNDLE_HTTPS://GEMS__EXAMPLE__COM:8080/: [FILTERED]" ],
      [ "heredoc-dash-quoted", "config/boot.rb", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = <<-'EOS'\n  usr7k:Pw9\n  T4il\n  EOS\nputs :after",
        "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = <<-'EOS'\n  [FILTERED]\n  [FILTERED]\n  EOS\nputs :after" ],
      [ "yaml-literal-block", "docker-compose.yml", "  environment:\n    BUNDLE_GEMS__EXAMPLE__COM: |\n      usr7k:Pw9\n      T4il\n    OTHER: 1",
        "  environment:\n    BUNDLE_GEMS__EXAMPLE__COM: |\n      [FILTERED]\n      [FILTERED]\n    OTHER: 1" ],
      [ "yaml-sq-two-lines", "docker-compose.yml", "    BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9\n      T4il'\n    OTHER: 1",
        "    BUNDLE_GEMS__EXAMPLE__COM: '[FILTERED]\n      [FILTERED]'\n    OTHER: 1" ],
      [ "ruby-continuation", "config/boot.rb", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"usr7k:Pw9 T4il\"\\\nnext",
        "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \"[FILTERED]\"\\\nnext" ],
      [ "escaped-in-echo", "Dockerfile", "RUN echo \"BUNDLE_GEMS__EXAMPLE__COM: \\\"usr7k:Pw9 T4il\\\"\" >> /usr/local/bundle/config",
        "RUN echo \"BUNDLE_GEMS__EXAMPLE__COM: \\\"[FILTERED]\\\"\" >> /usr/local/bundle/config" ],
      [ "two-settings-one-line", "bin/setup", "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9 T4il\" BUNDLE_JOBS=4",
        "export BUNDLE_GEMS__EXAMPLE__COM=\"[FILTERED]\" BUNDLE_JOBS=4" ],
      [ "fish-gx", "bin/setup", "set -gx BUNDLE_GEMS__EXAMPLE__COM 'usr7k:Pw9 T4il'",
        "set -gx BUNDLE_GEMS__EXAMPLE__COM '[FILTERED]'" ],
      [ "continued-value", "Dockerfile", "RUN bundle config set gems.example.com \\\n    \"usr7k:Pw9 T4il\" && bundle install\nRUN echo done",
        "RUN bundle config set gems.example.com \\\n    \"[FILTERED]\" && bundle install\nRUN echo done" ],
      [ "continued-env", "Dockerfile", "ENV BUNDLE_GEMS__EXAMPLE__COM=\\\n  usr7k:Pw9\nENV X=1",
        "ENV BUNDLE_GEMS__EXAMPLE__COM=\\\n  [FILTERED]\nENV X=1" ],
      [ "json-mapping-lines", "app.json", "{\n  \"env\": {\n    \"BUNDLE_GEMS__EXAMPLE__COM\": {\n      \"value\": \"usr7k:Pw9 T4il\"\n    }\n  }\n}",
        "{\n  \"env\": {\n    \"BUNDLE_GEMS__EXAMPLE__COM\": {\n      \"value\": \"[FILTERED]\"\n    }\n  }\n}" ],
      [ "config-heredoc-in-run", "Dockerfile", "RUN cat > .bundle/config <<EOF\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9 T4il\nEOF",
        "RUN cat > .bundle/config <<EOF\nBUNDLE_GEMS__EXAMPLE__COM: [FILTERED]\nEOF" ],
      [ "js-env-property", "src/env.js", "process.env.BUNDLE_GEMS__EXAMPLE__COM = 'usr7k:Pw9T4il';",
        "process.env.BUNDLE_GEMS__EXAMPLE__COM = '[FILTERED]';" ],
      [ "cmd-setx", "bin/setup.cmd", "setx BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9T4il",
        "setx BUNDLE_GEMS__EXAMPLE__COM [FILTERED]" ],
      [ "ruby-hash-bare-name", "config/boot.rb", "h = {\n  BUNDLE_JOBS: 4,\n  BUNDLE_GEMS__EXAMPLE__COM: creds,\n}",
        "h = {\n  BUNDLE_JOBS: 4,\n  BUNDLE_GEMS__EXAMPLE__COM: creds,\n}" ]
  ].freeze
end

# Collects the forms of a fixture file written as c(path, label, text) or k(path, text).
class BundlerFormSet
  attr_reader :forms

  def self.load(name)
    set = new
    file = File.expand_path("../../fixtures/redaction/#{name}", __dir__)
    set.instance_eval(File.read(file), file)
    set.forms
  end

  def initialize
    @forms = []
  end

  # Forms written as `@ <file kind> <label>` over the text, as the review files are; a label ending in `~`
  # spells \r, \t and \0 out.
  def self.text(name)
    file = File.expand_path("../../fixtures/redaction/#{name}", __dir__)
    forms = []
    File.binread(file).force_encoding("UTF-8").each_line do |line|
      if line.start_with?("@ ")
        _, path, label = line.chomp.split(" ", 3)
        forms << [ path, label, +"" ]
      elsif forms.any?
        forms.last[2] << line
      end
    end
    forms.map do |path, label, text|
      text = text.chomp
      text = text.gsub("\\r", "\r").gsub("\\t", "\t").gsub("\\0", "\0") if label.end_with?("~")
      [ path, label, text ]
    end
  end

  def c(path, label, text) = @forms << [ path, label, text.chomp ]
  def k(path, text) = @forms << [ path, text.chomp ]
end

RSpec.describe RailsAiContext::Redaction, "gem server credentials" do
  # What a form is not a finding for: Bundler reads these as something else, or the marker is the text itself.
  not_a_credential = {
    "E16-empty-then-next" => "an env file does not continue a value on the next line",
    "R50-rb-comment-after" => "the comment repeats the marker",
    "S48-cfg-no-space-eq" => "`bundle config a.b=value` is not a Bundler form",
    "N61-cfg-single-label-host" => "Bundler reads a name with no dot and no port as a setting",
    "N62-env-single-label" => "Bundler reads BUNDLE_GEMSERVER as a setting",
    "N63-env-single-label-2" => "Bundler reads BUNDLE_GEMS as a setting",
    "N69-env-lower-bundle" => "Bundler reads upper-case names only",
    "C5-mixed-case-name" => "Bundler reads upper-case names only",
    "E15-lowercase-var" => "Bundler reads upper-case names only",
    "E30-double-eq" => "`==` is a comparison, not an assignment",
    "S17-vars-assigned-first" => "the secret is assigned on an earlier statement, to variables the name does not name",
    "S35-xargs" => "the secret is piped to the command, not written after the host",
    "N64-url-basic-auth-curl" => "`curl -u` is not a Bundler setting",
    "N77-env-host-localhost" => "a name with no dot and no port is a setting to Bundler",
    "N79-env-single-label" => "a name with no dot and no port is a setting to Bundler",
    "N85-yaml-value-with-space-hash" => "` #` starts a YAML comment",
    "N132-ini-section" => "an INI file is no Bundler setting file",
    "R61-config-attr" => "a Ruby attribute that is not a BUNDLE_ name or a gem server"
  }
  # Prose that names a setting loses the words after it: it cannot be told from a value.
  prose = [ %(abort "set BUNDLE_GEMS__EXAMPLE__COM first"), "BUNDLE_GEMS__EXAMPLE__COM: see below" ]
  prose_labels = %w[O20-log-colon O72-yaml-comment]

  def filtered(path, text)
    text.include?("\n") ? described_class.redact_source(text, path: path) : described_class.redact_source_line(text, path: path)
  end

  it "filters a credential found by its name, in every file kind and quoting, and keeps the code around it" do
    BundlerCredentialRows::ROWS.each do |label, path, input, expected|
      shown = described_class.redact_source(input, path: path)
      expect(shown).to eq(expected), "#{label}: #{shown.inspect}"
      next unless BundlerCredentialRows::SECRET_PARTS.any? { |part| input.include?(part) }

      leaked = BundlerCredentialRows::SECRET_PARTS.select { |part| shown.include?(part) }
      expect(leaked).to eq([]), "#{label} leaked #{leaked}"
      expect(described_class.source_slice(input, path: path)).to eq(expected), label
      expect(described_class.redact_source(input + "\n", path: path)).to eq(expected + "\n"), label
    end
  end

  it "leaves no part of the credential in any form of the leak corpus" do
    forms = BundlerFormSet.load("bundler_leak_forms.rb").reject { |_, label, _| not_a_credential.key?(label) }
    expect(forms.size).to be > 500
    forms.each do |path, label, text|
      shown = filtered(path, text)
      leaked = BundlerCredentialRows::SECRET_PARTS.select { |part| text.include?(part) && shown.include?(part) }
      expect(leaked).to eq([]), "#{label} [#{path}] leaked #{leaked}: #{shown.inspect}"
    end
  end

  it "leaves no part of the credential in any form of the third review's files" do
    forms = %w[f1 f2 f3].flat_map { |name| BundlerFormSet.text("bundler_forms_#{name}.txt") }
    expect(forms.size).to be > 450
    forms.reject { |_, label, _| not_a_credential.key?(label) }.each do |path, label, text|
      shown = described_class.redact_source(text, path: path)
      leaked = BundlerCredentialRows::SECRET_PARTS.select { |part| text.include?(part) && shown.include?(part) }
      expect(leaked).to eq([]), "#{label} [#{path}] leaked #{leaked}: #{shown.inspect}"
    end
  end

  it "keeps what the third review's kept forms hold, apart from prose that names a setting" do
    forms = BundlerFormSet.text("bundler_forms_o1.txt").reject { |_, label, _| prose_labels.include?(label) }
    expect(forms.size).to be > 120
    forms.each do |path, label, text|
      shown = described_class.redact_source(text, path: path)
      expect(shown).to eq(text), "#{label} [#{path}] became #{shown.inspect}"
    end
  end

  it "keeps the code, the names and the references of every form of the kept corpus" do
    forms = BundlerFormSet.load("bundler_kept_forms.rb").reject { |_, text| prose.include?(text) }
    expect(forms.size).to be > 150
    forms.each do |path, text|
      shown = filtered(path, text)
      expect(shown).to eq(text), "[#{path}] #{text.inspect} became #{shown.inspect}"
    end
  end

  it "reads an invalid byte, or text in UTF-16, instead of raising" do
    shown = described_class.redact_source_line("export BUNDLE_A__B=\"usr7k:Pw9\xFFT4il\"", path: "bin/setup")
    expect(shown).to eq(%(export BUNDLE_A__B="[FILTERED]"))
    expect(described_class.redact_source("a\xFF\nBUNDLE_A__B=usr7k:Pw9T4il\n".dup.force_encoding("UTF-8"), path: "bin/setup")).to eq("a\uFFFD\nBUNDLE_A__B=[FILTERED]\n")
    expect(described_class.redact_source("BUNDLE_A__B=usr7k:Pw9T4il".encode("UTF-16LE"), path: "bin/setup")).to eq("BUNDLE_A__B=[FILTERED]")
    expect(described_class.redact_source("hello".encode("UTF-16LE"), path: "bin/setup")).to eq("hello")
  end

  it "filters a value longer than the part of the word after a name that is read to judge it" do
    long = ("Ab" * 140) + "7k:Pw9T4il"
    [ "BUNDLE_A__B is #{long}", "BUNDLE_A__B #{long}", "# BUNDLE_A__B to #{long}" ].each do |line|
      %w[config/boot.rb bin/setup docker-compose.yml].each do |path|
        expect(described_class.redact_source(line, path: path)).not_to include("Pw9T4il"), "#{path}: #{line[0, 20]}"
      end
    end
  end

  # Each credential start used to scan on to the end of the line, so these cost the square of the line.
  it "reads a line of many credential starts, quotes and parts in linear time", :cpu_timed do
    skip "a Windows runner times these shapes past the example limit; Linux and macOS time the same scanners" if Gem.win_platform?

    shapes = {
      ->(size) { %(BUNDLE_A=") * (size / 10) } => 600_000,
      ->(size) { %(BUNDLE_A: ") * (size / 11) } => 600_000,
      ->(size) { %(BUNDLE_A__B=x ) * (size / 14) } => 600_000,
      ->(size) { %(BUNDLE_A__B="é) * (size / 14) } => 600_000,
      ->(size) { %(bundle config a.b ") * (size / 19) } => 600_000,
      ->(size) { %(bundle config a.b ') * (size / 19) } => 600_000,
      ->(size) { "BUNDLE_A__B=$x;" * (size / 15) } => 600_000,
      ->(size) { "BUNDLE_A__B=$x," * (size / 15) } => 600_000,
      ->(size) { %(BUNDLE_A__B=$x") * (size / 15) } => 600_000,
      ->(size) { "BUNDLE_A__B=nil;" * (size / 16) } => 600_000,
      ->(size) { "BUNDLE_A__B=:a;" * (size / 15) } => 600_000,
      ->(size) { "BUNDLE_A__B={{;" * (size / 15) } => 600_000,
      ->(size) { %(ENV["BUNDLE_A__B"]=ENV["x"] ;) * (size / 26) } => 600_000,
      ->(size) { "BUNDLE_A__B={{ " + ('"\\"' * (size / 3)) } => 150_000,
      ->(size) { %(BUNDLE_A__B="${{ ) + (%("\\') * (size / 3)) } => 150_000,
      ->(size) { %(x="BUNDLE_A__B=\\"a) + ('\\"' * (size / 2)) } => 150_000,
      ->(size) { "BUNDLE_A__B=${x:-${y:-" * (size / 21) } => 150_000,
      ->(size) { "BUNDLE_A__B=$(" * (size / 14) } => 150_000,
      ->(size) { "BUNDLE_A__B=foo(" * (size / 16) } => 150_000,
      ->(size) { %(ENV["BUNDLE_A__B"] = a) + (".b" * (size / 2)) } => 400_000,
      ->(size) { %(ENV["BUNDLE_A__B"] = a) + (".b()" * (size / 4)) } => 400_000,
      ->(size) { %(ENV["BUNDLE_A__B"] = a) + ("(b)" * (size / 3)) } => 400_000,
      ->(size) { %(ENV["BUNDLE_A__B"] = a) + ("{b}" * (size / 3)) } => 400_000,
      ->(size) { "$(bundle config set a.b " * (size / 22) + ")" * (size / 22) } => 200_000,
      ->(size) { %(ENV["BUNDLE_A__B"] = "\#{) * (size / 22) + "}" * (size / 22) + '"' } => 200_000,
      ->(size) { "BUNDLE_A__B=$(" * (size / 14) + ")" * (size / 14) } => 200_000,
      ->(size) { "BUNDLE_A__B: <% " * (size / 16) } => 200_000,
      ->(size) { %(BUNDLE_A__B: {{ ") * (size / 17) } => 200_000,
      ->(size) { "BUNDLE_A__B=1 " * (size / 14) + "A" } => 300_000,
      ->(size) { %(ENV["BUNDLE_A__B"] =\n) * (size / 22) } => 300_000,
      ->(size) { "bundle config set a.b \\\n" * (size / 22) } => 300_000,
      ->(size) { "BUNDLE_A__B=[a, " * (size / 16) } => 150_000,
      ->(size) { "BUNDLE_A__B=" + ("'" * size) } => 150_000,
      ->(size) { "BUNDLE_A__B=" + (%("a) * (size / 2)) } => 150_000,
      ->(size) { "BUNDLE_A__B=" + (%("a"'b') * (size / 6)) } => 150_000,
      ->(size) { "bundle config set a.b 'a" + ("'\\''" * (size / 4)) } => 150_000,
      ->(size) { "BUNDLE_A__B <a " * (size / 15) } => 200_000,
      ->(size) { "BUNDLE_A__B-" * (size / 12) } => 200_000,
      ->(size) { "BUNDLE_-" * (size / 8) } => 200_000,
      ->(size) { "ENV['BUNDLE_A__B'] = a ||\n" * (size / 24) } => 200_000,
      ->(size) { "RUN bundle config set a.b \\\n# c\n" * (size / 30) } => 200_000
    }
    paths = [ "docker-compose.yml", "bin/setup", "config/boot.rb", ".env" ]
    # Eight times the input costs about 8 times the CPU when linear and 64 times when quadratic, on any machine.
    shapes.each_with_index do |(shape, size), index|
      small = shape.call(size / 8)
      line = shape.call(size)
      paths.each do |path|
        base = cpu_seconds(gc: false) { described_class.redact_source(small, path: path) }
        limit = 24 * [ base, 0.03 ].max
        # A slow moment on a shared runner is not the scan's cost, so a call over the limit runs again; a quadratic one never gets under.
        tries = [ cpu_seconds(gc: false) { described_class.redact_source(line, path: path) } ]
        tries << cpu_seconds(gc: false) { described_class.redact_source(line, path: path) } while tries.min >= limit && tries.size < 3
        expect(tries.min).to be < limit, "shape #{index} in #{path}: #{base.round(3)}s then #{tries.map { |s| s.round(3) }}"
      end
    end
  end
end
