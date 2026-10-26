# frozen_string_literal: true

# Forms a gem server credential is written in, one per line: c(file kind, label, text). Every credential in
# them is the fake pair usr7k:Pw9T4il, and none of its three parts may come out of the redaction.
# --- Dockerfile
c "Dockerfile", "D01-env-dq", %q(ENV BUNDLE_GEMS__EXAMPLE__COM="usr7k:Pw9T4il")
c "Dockerfile", "D02-env-space-form", %q(ENV BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9T4il)
c "Dockerfile", "D03-env-two", %q(ENV BUNDLE_A__B=usr7k:Pw9 BUNDLE_C__D=T4il)
c "Dockerfile", "D04-arg", %q(ARG BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il)
c "Dockerfile", "D05-run-export-sq-nested", %q(RUN export BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9'"'"'T4il' && bundle install)
c "Dockerfile", "D06-run-bc-continuation", "RUN bundle config set gems.example.com \\\n    usr7k:Pw9T4il && bundle install"
c "Dockerfile", "D07-run-bc-split-bs", "RUN bundle config set gems.example.com usr7k:\\\nPw9T4il"
c "Dockerfile", "D08-env-json-form", %q(ENV ["BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il"])
c "Dockerfile", "D09-run-exec-form", %q(RUN ["bundle", "config", "set", "gems.example.com", "usr7k:Pw9T4il"])
c "Dockerfile", "D10-ucase-host", %q(RUN bundle config set GEMS.EXAMPLE.COM usr7k:Pw9T4il)
c "Dockerfile", "D11-port", %q(RUN bundle config set gems.example.com:8080 usr7k:Pw9T4il)
c "Dockerfile", "D12-url-key-userinfo", %q(RUN bundle config set https://usr7k:Pw9@gems.example.com/ T4il)
c "Dockerfile", "D13-url-key", %q(RUN bundle config set https://gems.example.com/ usr7k:Pw9T4il)
c "Dockerfile", "D14-env-url-key", %q(ENV BUNDLE_HTTPS://GEMS.EXAMPLE.COM/=usr7k:Pw9T4il)
c "Dockerfile", "D15-github-com", %q(ENV BUNDLE_GITHUB__COM=usr7k:Pw9T4il)
c "Dockerfile", "D16-github-com-x-oauth", %q(ENV BUNDLE_GITHUB__COM="usr7k:x-oauth-basic")
c "Dockerfile", "D17-sq-ansi-c", %q(ENV BUNDLE_A__B=$'usr7k\'Pw9T4il')
c "Dockerfile", "D18-dq-escaped-quote", %q(ENV BUNDLE_A__B="usr7k\"Pw9T4il")
c "Dockerfile", "D19-bs-at-eol", %q(RUN bundle config set a.b "usr7k\\)
c "Dockerfile", "D20-two-cfg-same-line", %q(RUN bundle config set a.b usr7k:Pw9 && bundle config set c.d T4il)
c "Dockerfile", "D21-no-space-after-other", %q(RUN bundle config set a.b x&&export BUNDLE_C__D=usr7k:Pw9T4il)
c "Dockerfile", "D22-literal-user-var-pw", %q(ENV BUNDLE_A__B="usr7k:${PASS}")
c "Dockerfile", "D23-cmd-subst", %q(ENV BUNDLE_A__B="usr7k:$(cat /run/secrets/x)")
c "Dockerfile", "D24-lit-then-dollar", %q(RUN bundle config set a.b usr7k:$PASS)
c "Dockerfile", "D25-pw-with-dollar", %q(RUN bundle config set a.b 'usr7k:Pw9$T4il')
c "Dockerfile", "D26-dq-dollar-mid", %q(RUN bundle config set a.b "usr7k:Pw9$T4il")
c "Dockerfile", "D27-bare-dollar-mid", %q(RUN bundle config set a.b usr7k:Pw9$T4il)
c "Dockerfile", "D28-heredoc-run", "RUN <<EOF\nbundle config set a.b usr7k:Pw9T4il\nEOF"
c "Dockerfile", "D29-heredoc-env-value", "RUN <<EOF\nexport BUNDLE_A__B=<<X\nusr7k:Pw9T4il\nX\nEOF"
c "Dockerfile", "D30-tabs", "RUN\tbundle\tconfig\tset\ta.b\tusr7k:Pw9T4il"
c "Dockerfile", "D31-env-tab", "ENV\tBUNDLE_A__B\tusr7k:Pw9T4il"
c "Dockerfile", "D32-lower-env", %q(env BUNDLE_A__B=usr7k:Pw9T4il)
# --- compose
c "docker-compose.yml", "Y01-env-map", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\n  OTHER: x"
c "docker-compose.yml", "Y02-env-list", "environment:\n  - BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\n  - OTHER=x"
c "docker-compose.yml", "Y03-env-list-dq", "environment:\n  - \"BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\""
c "docker-compose.yml", "Y04-args", "build:\n  args:\n    BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\""
c "docker-compose.yml", "Y05-folded", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: >-\n    usr7k:Pw9T4il\n  OTHER: x"
c "docker-compose.yml", "Y06-literal-block", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: |\n    usr7k:Pw9\n    T4il\n  OTHER: x"
c "docker-compose.yml", "Y07-multiline-plain", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9\n    T4il\n  OTHER: x"
c "docker-compose.yml", "Y08-multiline-dq", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9\n    T4il\"\n  OTHER: x"
c "docker-compose.yml", "Y09-multiline-sq", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: 'usr7k:Pw9\n    T4il'\n  OTHER: x"
c "docker-compose.yml", "Y10-label-next-line", "environment:\n  - name: BUNDLE_GEMS__EXAMPLE__COM\n    value: usr7k:Pw9T4il"
c "docker-compose.yml", "Y11-label-next-line-dq", "env:\n  - name: \"BUNDLE_GEMS__EXAMPLE__COM\"\n    value: \"usr7k:Pw9T4il\""
c "docker-compose.yml", "Y12-flow-map", %q(environment: { BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il, OTHER: x })
c "docker-compose.yml", "Y13-flow-map-dq", %q(environment: { "BUNDLE_GEMS__EXAMPLE__COM": "usr7k:Pw9T4il", "OTHER": "x" })
c "docker-compose.yml", "Y14-flow-seq", %q(environment: ["BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il", "OTHER=x"])
c "docker-compose.yml", "Y15-trailing-comment", "A: 1\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il # prod"
c "docker-compose.yml", "Y16-anchor", "BUNDLE_GEMS__EXAMPLE__COM: &cred usr7k:Pw9T4il"
c "docker-compose.yml", "Y17-tag", "BUNDLE_GEMS__EXAMPLE__COM: !!str usr7k:Pw9T4il"
c "docker-compose.yml", "Y18-crlf", "environment:\r\n  BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\r\n  OTHER: x\r\n"
c "docker-compose.yml", "Y19-block-crlf", "BUNDLE_GEMS__EXAMPLE__COM: |\r\n  usr7k:Pw9T4il\r\nOTHER: x\r\n"
c "docker-compose.yml", "Y20-key-colon-space-many", "BUNDLE_GEMS__EXAMPLE__COM:      usr7k:Pw9T4il"
c "docker-compose.yml", "Y21-key-tab", "BUNDLE_GEMS__EXAMPLE__COM:\tusr7k:Pw9T4il"
c "docker-compose.yml", "Y22-quoted-key-sq", %q('BUNDLE_GEMS__EXAMPLE__COM': 'usr7k:Pw9T4il')
c "docker-compose.yml", "Y23-explicit-key", "? BUNDLE_GEMS__EXAMPLE__COM\n: usr7k:Pw9T4il"
c "docker-compose.yml", "Y24-value-on-next-line", "BUNDLE_GEMS__EXAMPLE__COM:\n  usr7k:Pw9T4il"
c "docker-compose.yml", "Y25-value-next-line-dq", "BUNDLE_GEMS__EXAMPLE__COM:\n  \"usr7k:Pw9T4il\""
c "docker-compose.yml", "Y26-json-style", %q({"BUNDLE_GEMS__EXAMPLE__COM": "usr7k:Pw9T4il", "x": 1})
# --- CI
c ".github/workflows/ci.yml", "G01-env", "env:\n  BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c ".github/workflows/ci.yml", "G02-run-bc", "- run: bundle config set --local gems.example.com usr7k:Pw9T4il"
c ".github/workflows/ci.yml", "G03-run-bc-dq", %q(- run: bundle config set --local gems.example.com "usr7k:Pw9T4il")
c ".github/workflows/ci.yml", "G04-run-block", "- run: |\n    bundle config set gems.example.com usr7k:Pw9T4il\n    bundle install"
c ".github/workflows/ci.yml", "G05-run-folded", "- run: >\n    bundle config set gems.example.com\n    usr7k:Pw9T4il"
c ".github/workflows/ci.yml", "G06-with-expr-user", "env:\n  BUNDLE_GEMS__EXAMPLE__COM: usr7k:${{ secrets.PW }}"
c ".github/workflows/ci.yml", "G07-expr-user-pw-lit", "env:\n  BUNDLE_GEMS__EXAMPLE__COM: ${{ secrets.U }}:usr7k"
c ".github/workflows/ci.yml", "G08-run-dq-yaml-sq", %q(- run: 'bundle config set gems.example.com usr7k:Pw9T4il')
c ".github/workflows/ci.yml", "G09-run-dq-yaml-dq", %q(- run: "bundle config set gems.example.com usr7k:Pw9T4il")
c ".github/workflows/ci.yml", "G10-nested-yaml-sq-in-dq", %q(- run: "bundle config set gems.example.com 'usr7k:Pw9T4il'")
c ".github/workflows/ci.yml", "G11-nested-yaml-dq-in-sq", %q(- run: 'bundle config set gems.example.com "usr7k:Pw9T4il"')
c ".github/workflows/ci.yml", "G12-nested-esc", %q(- run: "bundle config set gems.example.com \"usr7k:Pw9T4il\"")
c ".gitlab-ci.yml", "L01-variables", "variables:\n  BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\""
c ".gitlab-ci.yml", "L02-script", "script:\n  - bundle config set gems.example.com usr7k:Pw9T4il"
c ".gitlab-ci.yml", "L03-script-dq-wrap", %q(  - 'bundle config gems.example.com "usr7k:Pw9T4il"')
c ".gitlab-ci.yml", "L04-script-multiline", "script:\n  - >\n    bundle config set gems.example.com\n    usr7k:Pw9T4il"
c ".gitlab-ci.yml", "L05-script-colon-sp", %q(  - "bundle config set gems.example.com: usr7k:Pw9T4il")
# --- .bundle/config
c ".bundle/config", "B01-plain", "---\nBUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\""
c ".bundle/config", "B02-bare", "---\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\nBUNDLE_PATH: vendor"
c ".bundle/config", "B03-space-in", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9 T4il"
c ".bundle/config", "B04-url-key", "BUNDLE_HTTPS://GEMS.EXAMPLE.COM/: usr7k:Pw9T4il"
c ".bundle/config", "B05-url-key-port", "BUNDLE_HTTPS://GEMS.EXAMPLE.COM:8080/: usr7k:Pw9T4il"
c ".bundle/config", "B06-port-only", "BUNDLE_GEMS__EXAMPLE__COM:8080: usr7k:Pw9T4il"
c ".bundle/config", "B07-block", "BUNDLE_GEMS__EXAMPLE__COM: |-\n  usr7k:Pw9T4il\nBUNDLE_PATH: v"
c ".bundle/config.example", "B08-example", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c ".bundle/config.sample", "B09-sample", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c ".bundle/config.bak", "B10-bak", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c "bundle/config", "B11-no-dot", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c "config/bundle_config", "B12-plain-name", "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c ".bundle/config", "B13-github", "BUNDLE_GITHUB__COM: usr7k:Pw9T4il"
c ".bundle/config", "B14-crlf", "---\r\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\r\nBUNDLE_PATH: v\r\n"
c ".bundle/config", "B15-lowercase-host-key", "BUNDLE_gems__example__com: usr7k:Pw9T4il"
# --- .env
c ".env.example", "E01", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il"
c ".env", "E02-export", "export BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il"
c ".env", "E03-space-val", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il"
c ".env", "E04-comment", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il # prod"
c ".env", "E05-hash-inside", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9#T4il"
c ".env", "E06-dq-multi", "BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9\nT4il\"\nOTHER=x"
c ".env", "E07-sq-multi", "BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9\nT4il'\nOTHER=x"
c ".env.production", "E08-bs-cont", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9\\\nT4il"
c ".env", "E09-crlf", "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\r\nOTHER=x\r\n"
c ".env", "E10-spaces-around-eq", "BUNDLE_GEMS__EXAMPLE__COM = usr7k:Pw9T4il"
c ".env", "E11-two-nospace", "BUNDLE_A__B=usr7k:Pw9;BUNDLE_C__D=T4il"
c ".env", "E12-two-sp", "BUNDLE_A__B=usr7k:Pw9 BUNDLE_C__D=T4il"
c "app.env", "E13-app-env", "BUNDLE_A__B=usr7k:Pw9T4il"
c ".env.local.backup", "E14-weird", "BUNDLE_A__B=usr7k:Pw9T4il"
c ".env", "E15-url-key", "BUNDLE_HTTPS://GEMS.EXAMPLE.COM/=usr7k:Pw9T4il"
c ".env", "E16-empty-then-next", "BUNDLE_A__B=\nusr7k:Pw9T4il"
c ".env", "E17-unicode-quote", "BUNDLE_A__B=\u201Cusr7k:Pw9T4il\u201D"
c ".env", "E18-nul", "BUNDLE_A__B=usr7k:Pw9\u0000T4il"
c ".env", "E19-nbsp", "BUNDLE_A__B=usr7k:Pw9\u00A0T4il"
c ".env", "E20-bom", "\uFEFFBUNDLE_A__B=usr7k:Pw9T4il"
# --- Ruby
c "config/boot.rb", "R01-env-sq", %q(ENV['BUNDLE_GEMS__EXAMPLE__COM'] = 'usr7k:Pw9T4il')
c "config/boot.rb", "R02-fetch-default", %q(ENV.fetch('BUNDLE_GEMS__EXAMPLE__COM', 'usr7k:Pw9T4il'))
c "config/boot.rb", "R03-fetch-block", %q(ENV.fetch("BUNDLE_GEMS__EXAMPLE__COM") { "usr7k:Pw9T4il" })
c "config/boot.rb", "R04-concat", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:" + "Pw9T4il")
c "config/boot.rb", "R05-concat-var", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:" + pw + "Pw9T4il")
c "config/boot.rb", "R06-interp", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:#{pw}Pw9T4il")
c "config/boot.rb", "R07-interp-nested-q", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:#{ENV["X"]}Pw9T4il")
c "config/boot.rb", "R08-percent-q", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = %q(usr7k:Pw9T4il))
c "config/boot.rb", "R09-percent-Q-nest", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = %Q(usr7k:(Pw9)T4il))
c "config/boot.rb", "R10-percent-w", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = %w[usr7k:Pw9T4il].first)
c "config/boot.rb", "R11-percent-bare", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = %(usr7k:Pw9T4il))
c "config/boot.rb", "R12-percent-pipe", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = %q|usr7k:Pw9T4il|)
c "config/boot.rb", "R13-heredoc", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = <<~PW.strip\n  usr7k:Pw9T4il\nPW"
c "config/boot.rb", "R14-heredoc-raw", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = <<~'PW'.strip\n  usr7k:Pw9T4il\nPW"
c "config/boot.rb", "R15-heredoc-dash", "x = { \"BUNDLE_GEMS__EXAMPLE__COM\" => <<-PW }\n  usr7k:Pw9T4il\n  PW\nputs 1"
c "config/boot.rb", "R16-hash-rocket", %q(opts = { "BUNDLE_GEMS__EXAMPLE__COM" => "usr7k:Pw9T4il", "A" => 1 })
c "config/boot.rb", "R17-hash-sym", %q(opts = { "BUNDLE_GEMS__EXAMPLE__COM": "usr7k:Pw9T4il", a: 1 })
c "config/boot.rb", "R18-ternary", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ci ? "usr7k:Pw9T4il" : "other")
c "config/boot.rb", "R19-or-eq", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] ||= "usr7k:Pw9T4il")
c "config/boot.rb", "R20-or", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV["X"] || "usr7k:Pw9T4il")
c "config/boot.rb", "R21-system", %q(system("bundle", "config", "set", "gems.example.com", "usr7k:Pw9T4il"))
c "config/boot.rb", "R22-system-str", %q(system("bundle config set gems.example.com usr7k:Pw9T4il"))
c "config/boot.rb", "R23-backtick", "`bundle config set gems.example.com usr7k:Pw9T4il`"
c "config/boot.rb", "R24-percent-x", %q(%x(bundle config set gems.example.com usr7k:Pw9T4il))
c "config/boot.rb", "R25-bundler-settings", %q(Bundler.settings.set_global("gems.example.com", "usr7k:Pw9T4il"))
c "config/boot.rb", "R26-sq-esc-end", %q(ENV['BUNDLE_GEMS__EXAMPLE__COM'] = 'usr7k:Pw9T4il\\')
c "config/boot.rb", "R27-dq-esc-end", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9T4il\\")
c "config/boot.rb", "R28-sq-esc-sq", %q(ENV['BUNDLE_GEMS__EXAMPLE__COM'] = 'usr7k:Pw9\'T4il')
c "config/boot.rb", "R29-dq-esc-dq", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9\"T4il")
c "config/boot.rb", "R30-adjacent-lit", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:" "Pw9T4il")
c "config/boot.rb", "R31-adjacent-lit-3", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k" ':' "Pw9" 'T4il')
c "config/boot.rb", "R32-gemfile-source", %q(source "https://usr7k:Pw9T4il@gems.example.com")
c "Gemfile", "R33-source-block", %q(source "https://gems.example.com" do ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9T4il" end)
c "Gemfile", "R34-freeze", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9T4il".freeze)
c "Gemfile", "R35-chain-method", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9T4il".strip.downcase)
c "Gemfile", "R36-trailing-sp-comment", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9T4il" # t)
c "Gemfile", "R37-unicode-quote", "ENV[\"BUNDLE_GEMS__EXAMPLE__COM\"] = \u201Cusr7k:Pw9T4il\u201D"
c "config/boot.rb", "R38-sym-key", %q(config.bundler = { :BUNDLE_GEMS__EXAMPLE__COM => "usr7k:Pw9T4il" })
c "config/boot.rb", "R39-set-env-kw", %q(set_env(BUNDLE_GEMS__EXAMPLE__COM: "usr7k:Pw9T4il"))
c "config/boot.rb", "R40-kw-nospace", %q(set_env(BUNDLE_GEMS__EXAMPLE__COM:"usr7k:Pw9T4il"))
c "config/boot.rb", "R41-rb-rescue-mod", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "usr7k:Pw9T4il" rescue nil)
c "config/boot.rb", "R42-two-on-line", %q(ENV["BUNDLE_A__B"] = "usr7k:Pw9"; ENV["BUNDLE_C__D"] = "T4il")
c "config/boot.rb", "R43-two-nospace", %q(ENV["BUNDLE_A__B"]="usr7k:Pw9";ENV["BUNDLE_C__D"]="T4il")
c "lib/tasks/x.rake", "R44-sh", %q(sh "bundle config set gems.example.com usr7k:Pw9T4il")
c "lib/tasks/x.rake", "R45-sh-squote-in-dq", %q(sh "bundle config set gems.example.com 'usr7k:Pw9T4il'")
c "lib/tasks/x.rake", "R46-sh-dq-in-sq", %q(sh 'bundle config set gems.example.com "usr7k:Pw9T4il"')
c "lib/tasks/x.rake", "R47-sh-esc-dq-in-dq", %q(sh "bundle config set gems.example.com \"usr7k:Pw9T4il\"")
c "lib/tasks/x.rake", "R48-sh-esc-dq-in-dq-dyn", %q(sh "bundle config set gems.example.com \"usr7k:#{pw}T4il\"")
c "lib/tasks/x.rake", "R49-sh-sq-in-dq-esc", %q(sh "bundle config set gems.example.com 'usr7k:Pw9\'T4il'")
c "lib/tasks/x.rb", "R50-rb-comment-after", %q(ENV["BUNDLE_A__B"] = "usr7k:Pw9T4il" # Pw9)
c "lib/x.erb", "R51-erb", %q(<%= ENV["BUNDLE_A__B"] = "usr7k:Pw9T4il" %>)
c "lib/x.erb", "R52-erb-bare", %q(BUNDLE_A__B=usr7k:Pw9T4il <% x %>)
# --- shell
c "bin/setup", "S01-export", %q(export BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il)
c "bin/setup", "S02-export-dq", %q(export BUNDLE_GEMS__EXAMPLE__COM="usr7k:Pw9T4il")
c "bin/setup", "S03-inline", %q(BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il bundle install)
c "bin/setup", "S04-inline-dq", %q(BUNDLE_GEMS__EXAMPLE__COM="usr7k:Pw9 T4il" bundle install)
c "bin/setup", "S05-env-cmd", %q(env BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il bundle install)
c "bin/setup", "S06-bs-cont", "bundle config set gems.example.com usr7k:Pw9\\\nT4il"
c "bin/setup", "S07-bs-cont-before", "bundle config set gems.example.com \\\n  usr7k:Pw9T4il"
c "bin/setup", "S08-bs-cont-dq", "bundle config set gems.example.com \"usr7k:Pw9\\\nT4il\""
c "bin/setup", "S09-heredoc", "cat > .bundle/config <<EOF\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\nEOF"
c "bin/setup", "S10-heredoc-quoted", "cat > .bundle/config <<'EOF'\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\nEOF"
c "bin/setup", "S11-heredoc-dash", "cat <<-EOF\n\tBUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\n\tEOF"
c "bin/setup", "S12-echo-append", %q(echo "BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il" >> .bundle/config)
c "bin/setup", "S13-echo-append-sq", %q(echo 'BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il' >> .bundle/config)
c "bin/setup", "S14-printf", %q(printf 'BUNDLE_GEMS__EXAMPLE__COM=%s\n' 'usr7k:Pw9T4il')
c "bin/setup", "S15-printf-fmt", %q(printf "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\n" > .env)
c "bin/setup", "S16-ssh-quoted", %q(ssh host "export BUNDLE_GEMS__EXAMPLE__COM='usr7k:Pw9T4il'")
c "bin/setup", "S17-ssh-quoted2", %q(ssh host 'export BUNDLE_GEMS__EXAMPLE__COM="usr7k:Pw9T4il"')
c "bin/setup", "S18-ssh-quoted-bs", %q(ssh host "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9T4il\"")
c "bin/setup", "S19-docker-run-e", %q(docker run -e BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il img)
c "bin/setup", "S20-docker-run-e-dq", %q(docker run -e "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il" img)
c "bin/setup", "S21-docker-build-arg", %q(docker build --build-arg BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il .)
c "bin/setup", "S22-semicolon", %q(export BUNDLE_A__B=usr7k:Pw9T4il; bundle install)
c "bin/setup", "S23-pipe", %q(export BUNDLE_A__B=usr7k:Pw9T4il|cat)
c "bin/setup", "S24-subshell", %q((export BUNDLE_A__B=usr7k:Pw9T4il))
c "bin/setup", "S25-subshell-dq", %q((export BUNDLE_A__B="usr7k:Pw9T4il"))
c "bin/setup", "S26-backtick-in", "x=`BUNDLE_A__B=usr7k:Pw9T4il env`"
c "bin/setup", "S27-dollar-paren", "x=$(BUNDLE_A__B=usr7k:Pw9T4il env)"
c "bin/setup", "S28-dollar-paren-dq", %q(x=$(BUNDLE_A__B="usr7k:Pw9T4il" env))
c "bin/setup", "S29-brace", %q({ export BUNDLE_A__B=usr7k:Pw9T4il; })
c "bin/setup", "S30-if-then", %q(if true; then export BUNDLE_A__B=usr7k:Pw9T4il; fi)
c "bin/setup", "S31-ifs-curlies", %q(export BUNDLE_A__B=usr7k:Pw9{a,b}T4il)
c "bin/setup", "S32-lit-user-var", %q(export BUNDLE_A__B="usr7k:${PASS}")
c "bin/setup", "S33-lit-user-var-bare", %q(export BUNDLE_A__B=usr7k:${PASS})
c "bin/setup", "S34-lit-user-cmdsub", %q(export BUNDLE_A__B="usr7k:$(cat pw)")
c "bin/setup", "S35-var-user-lit-pw", %q(export BUNDLE_A__B="${USER}:Pw9T4il")
c "bin/setup", "S36-var-user-lit-pw-bare", %q(export BUNDLE_A__B=${USER}:Pw9T4il)
c "bin/setup", "S37-default-expansion", %q(export BUNDLE_A__B="${PW:-usr7k:Pw9T4il}")
c "bin/setup", "S38-default-expansion-bare", %q(export BUNDLE_A__B=${PW:-usr7k:Pw9T4il})
c "bin/setup", "S39-cfg-var-default", %q(bundle config set a.b "${PW:-usr7k:Pw9T4il}")
c "bin/setup", "S40-here-string", %q(read x <<< "BUNDLE_A__B=usr7k:Pw9T4il")
c "bin/setup", "S41-declare", %q(declare -x BUNDLE_A__B=usr7k:Pw9T4il)
c "bin/setup", "S42-local-readonly", %q(readonly BUNDLE_A__B=usr7k:Pw9T4il)
c "bin/setup", "S43-array-append", %q(args+=(-e "BUNDLE_A__B=usr7k:Pw9T4il"))
c "bin/setup", "S44-cfg-after-pipe", %q(echo x | bundle config set a.b usr7k:Pw9T4il)
c "bin/setup", "S45-cfg-sudo", %q(sudo -u deploy bundle config set a.b usr7k:Pw9T4il)
c "bin/setup", "S46-cfg-global-flag-mid", %q(bundle config set a.b --global usr7k:Pw9T4il)
c "bin/setup", "S47-cfg-delete-flag", %q(bundle config --local a.b usr7k:Pw9T4il)
c "bin/setup", "S48-cfg-no-space-eq", %q(bundle config a.b=usr7k:Pw9T4il)
c "bin/setup", "S49-cfg-bundle-exec", %q(bundle exec bundle config set a.b usr7k:Pw9T4il)
c "bin/setup", "S50-cfg-bs-in-val", %q(bundle config set a.b usr7k:Pw9\ T4il)
c "bin/setup", "S51-cfg-bs-at-end", %q(bundle config set a.b usr7k:Pw9T4il\)
c "bin/setup", "S52-cfg-ansi-c", %q(bundle config set a.b $'usr7k:Pw9\'T4il')
c "bin/setup", "S53-cfg-locale-dq", %q(bundle config set a.b $"usr7k:Pw9T4il")
c "bin/setup", "S54-cfg-brace-group", %q(bundle config set a.b usr7k:Pw9T4il}) 
c "bin/setup", "S55-cfg-comment-hash-inside", %q(bundle config set a.b usr7k:Pw9#T4il)
c "bin/setup", "S56-cfg-redirect-in", %q(bundle config set a.b usr7k:Pw9>T4il)
c "bin/setup", "S57-cfg-amp-in", %q(bundle config set a.b usr7k:Pw9&T4il)
c "bin/setup", "S58-cfg-comma-in", %q(bundle config set a.b usr7k,Pw9,T4il)
c "bin/setup", "S59-cfg-semi-in-q", %q(bundle config set a.b "usr7k;Pw9;T4il")
c "bin/setup", "S60-cfg-paren-in", %q(bundle config set a.b usr7k:Pw9)T4il)
# --- fish / ps / cmd
c "config.fish", "F01-set-x", %q(set -x BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9T4il)
c "config.fish", "F02-set-gx", %q(set -gx BUNDLE_GEMS__EXAMPLE__COM "usr7k:Pw9T4il")
c "config.fish", "F03-setx-win", %q(setx BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9T4il)
c "config.fish", "F04-set-sq", %q(set -gx BUNDLE_GEMS__EXAMPLE__COM 'usr7k:Pw9T4il')
c "config.fish", "F05-set-two-words", %q(set -gx BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9 T4il)
c "config.fish", "F06-set-U", %q(set -Ux BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9T4il)
c "config.fish", "F07-set-path-flag", %q(set --global --export BUNDLE_GEMS__EXAMPLE__COM usr7k:Pw9T4il)
c "setup.ps1", "P01-env", %q($env:BUNDLE_GEMS__EXAMPLE__COM = "usr7k:Pw9T4il")
c "setup.ps1", "P02-env-sq", %q($env:BUNDLE_GEMS__EXAMPLE__COM = 'usr7k:Pw9T4il')
c "setup.ps1", "P03-env-bare", %q($env:BUNDLE_GEMS__EXAMPLE__COM = usr7k:Pw9T4il)
c "setup.ps1", "P04-set-item", %q(Set-Item -Path Env:BUNDLE_GEMS__EXAMPLE__COM -Value "usr7k:Pw9T4il")
c "setup.ps1", "P05-setenv", %q([Environment]::SetEnvironmentVariable("BUNDLE_GEMS__EXAMPLE__COM", "usr7k:Pw9T4il", "User"))
c "setup.ps1", "P06-new-item", %q(New-Item -Name BUNDLE_GEMS__EXAMPLE__COM -Value 'usr7k:Pw9T4il' -Path Env:)
c "setup.ps1", "P07-bt-esc", %q($env:BUNDLE_GEMS__EXAMPLE__COM = "usr7k:Pw9`"T4il")
c "setup.ps1", "P08-cfg", %q(bundle config set --global gems.example.com "usr7k:Pw9T4il")
c "setup.ps1", "P09-sq-doubled", %q($env:BUNDLE_GEMS__EXAMPLE__COM = 'usr7k:Pw9''T4il')
c "setup.ps1", "P10-hashtable", %q(@{ BUNDLE_GEMS__EXAMPLE__COM = "usr7k:Pw9T4il" })
c "setup.cmd", "W01-set", %q(set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il)
c "setup.cmd", "W02-set-q", %q(set "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il")
c "setup.bat", "W03-set-sp", %q(set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il)
c "setup.bat", "W04-set-amp", %q(set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9&echo T4il)
c "setup.bat", "W05-@set", %q(@set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il)
c "setup.bat", "W06-setx", %q(setx BUNDLE_GEMS__EXAMPLE__COM "usr7k:Pw9T4il")
c "setup.bat", "W07-set-crlf", "set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\r\nset X=1\r\n"
c "setup.bat", "W08-cfg", %q(bundle config set gems.example.com usr7k:Pw9T4il)
c "setup.bat", "W09-pct", %q(set BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9%T4il%)
c "setup.bat", "W10-caret", %q(set BUNDLE_GEMS__EXAMPLE__COM=usr7k^&Pw9T4il)
c "setup.bat", "W11-set-p-dq-sp", %q(set "BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9 T4il")
c "setup.bat", "W12-set-pct-lit-user", %q(set BUNDLE_GEMS__EXAMPLE__COM=usr7k:%PASS%)
# --- JSON / TOML / k8s / Helm / Procfile
c "app.json", "J01-env-obj", %q({"env": {"BUNDLE_GEMS__EXAMPLE__COM": "usr7k:Pw9T4il"}})
c "app.json", "J02-value-kv", %q({"name": "BUNDLE_GEMS__EXAMPLE__COM", "value": "usr7k:Pw9T4il"})
c "app.json", "J03-pretty", "{\n  \"BUNDLE_GEMS__EXAMPLE__COM\": \"usr7k:Pw9T4il\",\n  \"x\": 1\n}"
c "app.json", "J04-name-value-split", "{\n  \"name\": \"BUNDLE_GEMS__EXAMPLE__COM\",\n  \"value\": \"usr7k:Pw9T4il\"\n}"
c "app.json", "J05-value-before-name", "{\n  \"value\": \"usr7k:Pw9T4il\",\n  \"name\": \"BUNDLE_GEMS__EXAMPLE__COM\"\n}"
c "app.json", "J06-escaped-json-string", %q({"cmd": "bundle config set gems.example.com \"usr7k:Pw9T4il\""})
c "app.json", "J07-escaped-env", %q({"cmd": "export BUNDLE_GEMS__EXAMPLE__COM=\"usr7k:Pw9T4il\""})
c "app.json", "J08-unicode-esc", %q({"BUNDLE_GEMS__EXAMPLE__COM": "usr7k\u003aPw9T4il"})
c "app.json", "J09-key-unicode-esc", %q({"BUNDLE_GEMS__EXAMPLE__COM": "usr7k:Pw9\"T4il"})
c "app.json", "J10-array-env", %q({"env": ["BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il"]})
c "app.json", "J11-minified-two", %q({"BUNDLE_A__B":"usr7k:Pw9","BUNDLE_C__D":"T4il"})
c "app.json", "J12-nested-json-str", %q({"v": "{\"BUNDLE_A__B\":\"usr7k:Pw9T4il\"}"})
c "app.json", "J13-nested-json-str-2", %q({"v": "{\\\"BUNDLE_A__B\\\":\\\"usr7k:Pw9T4il\\\"}"})
c "devcontainer.json", "J14-comment", "{\n  // BUNDLE\n  \"containerEnv\": {\"BUNDLE_A__B\": \"usr7k:Pw9T4il\"}\n}"
c "config.toml", "T01", %q(BUNDLE_GEMS__EXAMPLE__COM = "usr7k:Pw9T4il")
c "config.toml", "T02-sq", %q(BUNDLE_GEMS__EXAMPLE__COM = 'usr7k:Pw9T4il')
c "config.toml", "T03-inline-table", %q(env = { BUNDLE_GEMS__EXAMPLE__COM = "usr7k:Pw9T4il", X = "1" })
c "config.toml", "T04-ml", "BUNDLE_GEMS__EXAMPLE__COM = \"\"\"\nusr7k:Pw9T4il\n\"\"\""
c "config.toml", "T05-ml-lit", "BUNDLE_GEMS__EXAMPLE__COM = '''\nusr7k:Pw9T4il\n'''"
c "config.toml", "T06-quoted-key", %q("BUNDLE_GEMS__EXAMPLE__COM" = "usr7k:Pw9T4il")
c "config.toml", "T07-comment", %q(BUNDLE_GEMS__EXAMPLE__COM = "usr7k:Pw9T4il" # c)
c "config.toml", "T08-bare", %q(BUNDLE_GEMS__EXAMPLE__COM = usr7k:Pw9T4il)
c "values.yaml", "K01-helm-env", "env:\n  - name: BUNDLE_GEMS__EXAMPLE__COM\n    value: \"usr7k:Pw9T4il\""
c "values.yaml", "K02-helm-map", "extraEnv:\n  BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c "values.yaml", "K03-helm-tpl", "BUNDLE_GEMS__EXAMPLE__COM: {{ .Values.pw | default \"usr7k:Pw9T4il\" | quote }}"
c "values.yaml", "K04-helm-tpl-lit", "BUNDLE_GEMS__EXAMPLE__COM: {{ \"usr7k:Pw9T4il\" | quote }}"
c "deploy.yaml", "K05-k8s-env", "        env:\n        - name: BUNDLE_GEMS__EXAMPLE__COM\n          value: usr7k:Pw9T4il\n        - name: X\n          value: y"
c "deploy.yaml", "K06-k8s-configmap", "data:\n  BUNDLE_GEMS__EXAMPLE__COM: \"usr7k:Pw9T4il\""
c "deploy.yaml", "K07-k8s-stringdata", "stringData:\n  .bundle-config: |\n    BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c "deploy.yaml", "K08-k8s-args", "args: [\"bundle\", \"config\", \"set\", \"gems.example.com\", \"usr7k:Pw9T4il\"]"
c "deploy.yaml", "K09-k8s-cmd-list", "command:\n  - sh\n  - -c\n  - bundle config set gems.example.com usr7k:Pw9T4il && run"
c "deploy.yaml", "K10-k8s-cmd-sq", "command: [\"sh\", \"-c\", \"bundle config set gems.example.com 'usr7k:Pw9T4il' && run\"]"
c "deploy.yaml", "K11-k8s-label-name-indent-value-comment", "- name: BUNDLE_GEMS__EXAMPLE__COM\n  # secret\n  value: usr7k:Pw9T4il"
c "deploy.yaml", "K12-k8s-name-flow", "- {name: BUNDLE_GEMS__EXAMPLE__COM, value: 'usr7k:Pw9T4il'}"
c "deploy.yaml", "K13-k8s-name-flow-dq", %q(- { "name": "BUNDLE_GEMS__EXAMPLE__COM", "value": "usr7k:Pw9T4il" })
c "deploy.yaml", "K14-name-value-block", "- name: BUNDLE_GEMS__EXAMPLE__COM\n  value: |\n    usr7k:Pw9T4il"
c "deploy.yaml", "K15-name-value-fold", "- name: BUNDLE_GEMS__EXAMPLE__COM\n  value: >-\n    usr7k:Pw9T4il"
c "deploy.yaml", "K16-multi-doc", "---\n- name: BUNDLE_A__B\n  value: usr7k:Pw9\n---\n- name: BUNDLE_C__D\n  value: T4il"
c "Procfile", "PR01", "web: BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il bundle exec puma"
c "Procfile", "PR02-dq", %q(web: BUNDLE_GEMS__EXAMPLE__COM="usr7k:Pw9T4il" bundle exec puma)
c "Procfile", "PR03-cfg", "release: bundle config set gems.example.com usr7k:Pw9T4il && bundle install"
c "Procfile.dev", "PR04", "web: env BUNDLE_A__B=usr7k:Pw9T4il bin/rails s"
c "Makefile", "MK01", "\tbundle config set gems.example.com usr7k:Pw9T4il"
c "Makefile", "MK02-var", "BUNDLE_GEMS__EXAMPLE__COM := usr7k:Pw9T4il"
c "Makefile", "MK03-var-eq", "export BUNDLE_GEMS__EXAMPLE__COM = usr7k:Pw9T4il"
c "Makefile", "MK04-dollar2", "\tbundle config set gems.example.com usr7k:Pw9$$T4il"
c "Makefile", "MK05-q", "\t@bundle config set gems.example.com 'usr7k:Pw9T4il'"
c "Rakefile", "MK06-rake", "sh 'bundle config set gems.example.com usr7k:Pw9T4il'"
c "ansible.yml", "AN01", "- shell: bundle config set gems.example.com usr7k:Pw9T4il"
c "ansible.yml", "AN02-env", "  environment:\n    BUNDLE_GEMS__EXAMPLE__COM: \"{{ 'usr7k:Pw9T4il' }}\""
c "Vagrantfile", "VG01", %q(config.vm.provision "shell", inline: "bundle config set gems.example.com usr7k:Pw9T4il")
c "Vagrantfile", "VG02-env", %q(config.vm.provision "shell", env: { "BUNDLE_GEMS__EXAMPLE__COM" => "usr7k:Pw9T4il" })
c "Vagrantfile", "VG03-heredoc", "config.vm.provision \"shell\", inline: <<-SHELL\n  bundle config set gems.example.com usr7k:Pw9T4il\nSHELL"
# --- docs
c "README.md", "M01-span", "Run `bundle config set gems.example.com usr7k:Pw9T4il` first."
c "README.md", "M02-span-dq", "Run `bundle config set gems.example.com \"usr7k:Pw9T4il\"` first."
c "README.md", "M03-span-env", "Set `BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il` in CI."
c "README.md", "M04-span-env-sp", "Set `BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il` and `X=1`."
c "README.md", "M05-fence", "```sh\nbundle config set gems.example.com usr7k:Pw9T4il\n```"
c "README.md", "M06-fence-yaml", "```yaml\nBUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il\n```"
c "README.md", "M07-fence-dockerfile", "```dockerfile\nENV BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\n```"
c "README.md", "M08-fence-ruby", "```ruby\nENV['BUNDLE_GEMS__EXAMPLE__COM'] = 'usr7k:Pw9T4il'\n```"
c "README.md", "M09-fence-tilde", "~~~\nBUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il\n~~~"
c "README.md", "M10-indented-code", "    BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il"
c "README.md", "M11-table", "| `BUNDLE_GEMS__EXAMPLE__COM` | `usr7k:Pw9T4il` |"
c "README.md", "M12-table-eq", "| Var | `BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il` |"
c "README.md", "M13-link", "[cfg](x) `BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il`."
c "README.md", "M14-span-paren", "(`bundle config set gems.example.com usr7k:Pw9T4il`)"
c "README.md", "M15-span-comma", "Use `bundle config set gems.example.com usr7k:Pw9T4il`, then run."
c "README.md", "M16-bold", "**BUNDLE_GEMS__EXAMPLE__COM**=usr7k:Pw9T4il"
c "README.md", "M17-bold-colon", "**BUNDLE_GEMS__EXAMPLE__COM:** usr7k:Pw9T4il"
c "README.md", "M18-double-tick", "``BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il``"
c "README.md", "M19-bullets", "- BUNDLE_GEMS__EXAMPLE__COM: usr7k:Pw9T4il"
c "README.md", "M20-set-bash-prompt", "$ bundle config set gems.example.com usr7k:Pw9T4il"
c "docs/setup.rdoc", "M21-rdoc", "+BUNDLE_GEMS__EXAMPLE__COM+ is usr7k:Pw9T4il"
c "README.md", "M22-html", "<code>BUNDLE_GEMS__EXAMPLE__COM=usr7k:Pw9T4il</code>"
c "README.md", "M23-html-pre", "<pre>bundle config set gems.example.com usr7k:Pw9T4il</pre>"
c "README.md", "M24-html-entity", "BUNDLE_GEMS__EXAMPLE__COM=&quot;usr7k:Pw9T4il&quot;"
# --- stress forms
c ".env", "X01-long-value", "BUNDLE_A__B=usr7k:Pw9T4il" + "x" * 200_000
c ".env", "X02-long-dq", "BUNDLE_A__B=\"usr7k:Pw9T4il" + "x" * 200_000 + "\""
c "config/boot.rb", "X03-long-before", "x" * 200_000 + " ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il'"
c "config/boot.rb", "X04-nonascii-before", "é" * 50_000 + " ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il'"
c "config/boot.rb", "X05-nonascii-value", "ENV['BUNDLE_A__B'] = 'usr7kéééé:Pw9T4il'"
c "config/boot.rb", "X06-invalid-utf8", "ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il\xFF'"
c "config/boot.rb", "X07-invalid-utf8-before", "\xFF ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il'"
c "config/boot.rb", "X08-bs-run", "ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il" + "\\" * 1001
c "config/boot.rb", "X09-two-same-line-sq", "ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il'; ENV['BUNDLE_C__D'] = 'usr7k:Pw9T4il'"
c ".env", "X10-name-twice", "BUNDLE_A__B=BUNDLE_C__D=usr7k:Pw9T4il"
c ".env", "X11-name-as-value", "BUNDLE_A__B=BUNDLE_C__D"
c ".env", "X12-ws-value", "BUNDLE_A__B=   usr7k:Pw9T4il"
c "bin/setup", "X13-colon-op", "BUNDLE_A__B:usr7k:Pw9T4il"
c "bin/setup", "X14-name-then-newline-lit", "BUNDLE_A__B=\\\nusr7k:Pw9T4il"
c "config/boot.rb", "X15-bs-nl-dq", "ENV[\"BUNDLE_A__B\"] = \"usr7k:\\\nPw9T4il\""
c "config/boot.rb", "X16-percent-unclosed", "ENV['BUNDLE_A__B'] = %q(usr7k:Pw9\nT4il)"
c "config/boot.rb", "X17-percent-unclosed-ml", "ENV['BUNDLE_A__B'] = %q(usr7k:Pw9\nT4il)\nputs 1"
c "config/boot.rb", "X18-dq-ml", "ENV['BUNDLE_A__B'] = \"usr7k:Pw9\nT4il\"\nputs 1"
c "config/boot.rb", "X19-sq-ml", "ENV['BUNDLE_A__B'] = 'usr7k:Pw9\nT4il'\nputs 1"
c "config/boot.rb", "X20-heredoc-interp", "ENV['BUNDLE_A__B'] = <<~EOS\n  usr7k:Pw9\n  \#{x}T4il\nEOS"

c "bin/setup", "N01-cont-end", "bundle config set a.b usr7k:Pw9T4il\\"
c "bin/setup", "N02-paren", "bundle config set a.b usr7k:Pw9)T4il"
c "bin/setup", "N03-brace", "bundle config set a.b usr7k:Pw9}T4il"
c "bin/setup", "N04-var-user-sq", %q(export BUNDLE_A__B="$USER:Pw9T4il")
c "bin/setup", "N05-var-user-bare", %q(export BUNDLE_A__B=$USER:Pw9T4il)
c "bin/setup", "N06-var-pw", %q(export BUNDLE_A__B="usr7k:$PASS")
c "bin/setup", "N07-var-pw-bare", %q(export BUNDLE_A__B=usr7k:$PASS)
c "bin/setup", "N08-cmd-user", %q(export BUNDLE_A__B="$(whoami):Pw9T4il")
c "bin/setup", "N09-two-refs-lit-mid", %q(export BUNDLE_A__B="${U}:Pw9T4il@${H}")
c "bin/setup", "N10-cfg-ref-user", %q(bundle config set a.b "${U}:Pw9T4il")
c "bin/setup", "N11-cfg-ref-user-bare", %q(bundle config set a.b ${U}:Pw9T4il)
c "bin/setup", "N12-cfg-ref-user-2", %q(bundle config set a.b $U:Pw9T4il)
c "Dockerfile", "N13-env-ref", %q(ENV BUNDLE_A__B=${U}:Pw9T4il)
c "Dockerfile", "N14-run-ref", %q(RUN bundle config set a.b "$U:Pw9T4il")
c ".github/workflows/ci.yml", "N15-gh-expr-first", "env:\n  BUNDLE_A__B: ${{ secrets.U }}:Pw9T4il"
c ".github/workflows/ci.yml", "N16-gh-expr-first-dq", "env:\n  BUNDLE_A__B: \"${{ secrets.U }}:Pw9T4il\""
c ".github/workflows/ci.yml", "N17-gh-run", "- run: bundle config set a.b ${{ secrets.U }}:Pw9T4il"
c "config/boot.rb", "N18-rb-interp-first", %q(ENV["BUNDLE_A__B"] = "#{u}:Pw9T4il")
c "config/boot.rb", "N19-rb-env-first", %q(ENV["BUNDLE_A__B"] = ENV["U"] + ":Pw9T4il")
c "config/boot.rb", "N20-rb-env-interp", %q(ENV["BUNDLE_A__B"] = "#{ENV['U']}:Pw9T4il")
c "config/boot.rb", "N21-rb-fetch-chain", %q(ENV["BUNDLE_A__B"] = ENV.fetch("U") + ":Pw9T4il")
c "config/boot.rb", "N22-rb-fmt", %q(ENV["BUNDLE_A__B"] = format("%s:Pw9T4il", u))
c "config/boot.rb", "N23-rb-array-join", %q(ENV["BUNDLE_A__B"] = [u, "Pw9T4il"].join(":"))
c "config/boot.rb", "N24-rb-pct-s", %q(ENV["BUNDLE_A__B"] = "%s:Pw9T4il" % u)
c "config/boot.rb", "N25-rb-send-lit", %q(ENV["BUNDLE_A__B"] = creds || "usr7k:Pw9T4il")
c "config/boot.rb", "N26-rb-credentials-first", %q(ENV["BUNDLE_A__B"] = credentials.user + ":Pw9T4il")
c "config/boot.rb", "N27-rb-sym-then", %q(ENV["BUNDLE_A__B"] = :x.to_s + "Pw9T4il")
c "config/boot.rb", "N28-rb-nil-or", %q(ENV["BUNDLE_A__B"] = nil || "usr7k:Pw9T4il")
c "config/boot.rb", "N29-rb-true-and", %q(ENV["BUNDLE_A__B"] = true && "usr7k:Pw9T4il")
c "config/boot.rb", "N30-rb-File-read-plus", %q(ENV["BUNDLE_A__B"] = File.read("x") + "usr7k:Pw9T4il")
c "config/boot.rb", "N31-rb-ENV-bracket-or", %q(ENV["BUNDLE_A__B"] = ENV["X"] || 'usr7k:Pw9T4il')
c "config/boot.rb", "N32-rb-ENV-fetch-default", %q(ENV["BUNDLE_A__B"] = ENV.fetch("X", "usr7k:Pw9T4il"))
c "config/boot.rb", "N33-rb-ENV-dig", %q(ENV["BUNDLE_A__B"] = ENV.fetch("X") { "usr7k:Pw9T4il" })
c "config/boot.rb", "N34-rb-Rails-cred-or", %q(ENV["BUNDLE_A__B"] = Rails.application.credentials.x || "usr7k:Pw9T4il")
c "config/boot.rb", "N35-rb-File-in-str", %q(ENV["BUNDLE_A__B"] = "File.read('usr7k:Pw9T4il')")
c "config/boot.rb", "N36-dq-starts-ENV[", %q(ENV["BUNDLE_A__B"] = "ENV[usr7k:Pw9T4il")
c ".env", "N37-dotenv-ref-first", "BUNDLE_A__B=$U:Pw9T4il"
c ".env", "N38-dotenv-ref-first-braces", "BUNDLE_A__B=${U}:Pw9T4il"
c ".env", "N39-dotenv-expand-default", "BUNDLE_A__B=${P:-usr7k:Pw9T4il}"
c "values.yaml", "N40-helm-include", "BUNDLE_A__B: {{ include \"x\" . }}:Pw9T4il"
c "values.yaml", "N41-helm-quoted", "BUNDLE_A__B: \"{{ .Values.u }}:Pw9T4il\""
c "values.yaml", "N42-helm-lit-first", "BUNDLE_A__B: \"usr7k:{{ .Values.p }}\""
c "bin/setup", "N43-cfg-flag-after", %q(bundle config set a.b --global usr7k:Pw9T4il)
c "bin/setup", "N44-cfg-flag-after-2", %q(bundle config set a.b --local --parseable usr7k:Pw9T4il)
c "bin/setup", "N45-cfg-set-flag-between", %q(bundle config --global set a.b usr7k:Pw9T4il)
c "bin/setup", "N46-cfg-flag-eq", %q(bundle config set --scope=global a.b usr7k:Pw9T4il)
c "bin/setup", "N47-cfg-dash-short", %q(bundle config -g a.b usr7k:Pw9T4il)
c "bin/setup", "N48-cfg-env-prefix", %q(BUNDLE_APP_CONFIG=/x bundle config set a.b usr7k:Pw9T4il)
c "bin/setup", "N49-cfg-newline-key", "bundle config set \\\n  a.b \\\n  usr7k:Pw9T4il"
c "bin/setup", "N50-cfg-key-bs-continued", "bundle config set a.b \\\n  \"usr7k:Pw9T4il\""
c "bin/setup", "N51-cfg-quoted-key", %q(bundle config set "a.b" "usr7k:Pw9T4il")
c "bin/setup", "N52-cfg-sq-key", %q(bundle config set 'a.b' 'usr7k:Pw9T4il')
c "bin/setup", "N53-cfg-uppercase-key", %q(bundle config set GEMS.EXAMPLE.COM usr7k:Pw9T4il)
c "bin/setup", "N54-cfg-underscore-key", %q(bundle config set gems_example.com usr7k:Pw9T4il)
c "bin/setup", "N55-cfg-hyphen-key", %q(bundle config set my-gems.example.com usr7k:Pw9T4il)
c "bin/setup", "N56-cfg-ip-key", %q(bundle config set 10.0.0.1 usr7k:Pw9T4il)
c "bin/setup", "N57-cfg-localhost", %q(bundle config set localhost:9292 usr7k:Pw9T4il)
c "bin/setup", "N58-cfg-ipv6", %q(bundle config set "[::1]:9292" usr7k:Pw9T4il)
c "bin/setup", "N59-cfg-http-url-port-path", %q(bundle config set http://gems.example.com:8080/private/ usr7k:Pw9T4il)
c "bin/setup", "N60-cfg-url-userinfo-key", %q(bundle config set https://u:p@gems.example.com/ usr7k:Pw9T4il)
c "bin/setup", "N61-cfg-single-label-host", %q(bundle config set gemserver usr7k:Pw9T4il)
c "bin/setup", "N62-env-single-label", %q(export BUNDLE_GEMSERVER=usr7k:Pw9T4il)
c "bin/setup", "N63-env-single-label-2", %q(export BUNDLE_GEMS=usr7k:Pw9T4il)
c "bin/setup", "N64-env-digit-host", %q(export BUNDLE_10__0__0__1=usr7k:Pw9T4il)
c "bin/setup", "N65-env-hyphen-host", %q(export BUNDLE_MY_GEMS__EXAMPLE__COM=usr7k:Pw9T4il)
c "bin/setup", "N66-env-hyphen-raw", %q(export BUNDLE_MY-GEMS__EXAMPLE__COM=usr7k:Pw9T4il)
c "bin/setup", "N67-env-host-port-under", %q(export BUNDLE_GEMS__EXAMPLE__COM__8080=usr7k:Pw9T4il)
c "bin/setup", "N68-env-port-colon", %q(export BUNDLE_GEMS__EXAMPLE__COM:8080=usr7k:Pw9T4il)
c "bin/setup", "N69-env-lower-bundle", %q(export bundle_gems__example__com=usr7k:Pw9T4il)
c "bin/setup", "N70-env-ref-name", %q(export BUNDLE_${H}__COM=usr7k:Pw9T4il)
c ".env", "N71-dotenv-quoted-name", %q("BUNDLE_A__B"=usr7k:Pw9T4il)
c ".env", "N72-dotenv-yaml-ish", %q(BUNDLE_A__B: usr7k:Pw9T4il)
c "bin/setup", "N73-awk", %q(awk 'BEGIN{ENVIRON["BUNDLE_A__B"]="usr7k:Pw9T4il"}')
c "bin/setup", "N74-sed", %q(sed -i 's/^BUNDLE_A__B:.*/BUNDLE_A__B: usr7k:Pw9T4il/' .bundle/config)
c "bin/setup", "N75-sed-eq", %q(sed -i "s|BUNDLE_A__B=.*|BUNDLE_A__B=usr7k:Pw9T4il|" .env)
c "bin/setup", "N76-curl-header", %q(curl -H "BUNDLE_A__B: usr7k:Pw9T4il" x)
c "bin/setup", "N77-env-kv-in-sq-string", %q(sh -c 'export BUNDLE_A__B=usr7k:Pw9T4il; bundle install')
c "bin/setup", "N78-env-kv-in-dq-string", %q(sh -c "export BUNDLE_A__B=usr7k:Pw9T4il; bundle install")
c "bin/setup", "N79-env-kv-in-dq-string-q", %q(sh -c "export BUNDLE_A__B='usr7k:Pw9 T4il'; bundle install")
c "bin/setup", "N80-nested-sq-in-sq", %q(sh -c 'export BUNDLE_A__B='"'"'usr7k:Pw9T4il'"'"'; bundle install')
c "bin/setup", "N81-dq-in-dq-esc", %q(sh -c "export BUNDLE_A__B=\"usr7k:Pw9 T4il\"; bundle install")
c "bin/setup", "N82-dq-esc-two", %q(sh -c "export BUNDLE_A__B=\"usr7k:Pw9\" BUNDLE_C__D=\"T4il\"")
c "bin/setup", "N83-ssh-two-level", %q(ssh h "sh -c 'export BUNDLE_A__B=usr7k:Pw9T4il'")
c "bin/setup", "N84-dq-in-dq-in-sq", %q(ssh h 'sh -c "export BUNDLE_A__B=usr7k:Pw9T4il"')
c "bin/setup", "N85-eval-quoted", %q(eval "export BUNDLE_A__B='usr7k:Pw9T4il'")
c "bin/setup", "N86-bash-c-dollar", %q(bash -c $'export BUNDLE_A__B=usr7k:Pw9T4il')
c "bin/setup", "N87-trailing-quote-sp", %q(echo "BUNDLE_A__B=usr7k:Pw9T4il ")
c "bin/setup", "N88-name-adj-closer", %q(echo "x BUNDLE_A__B=usr7k:Pw9T4il" "y")
c "bin/setup", "N89-in-sq-array", %q(args=('BUNDLE_A__B=usr7k:Pw9T4il' 'x'))
c "bin/setup", "N90-in-dq-array", %q(args=("BUNDLE_A__B=usr7k:Pw9 T4il" "x"))
c "config/boot.rb", "N91-rb-array", %q(%w[BUNDLE_A__B=usr7k:Pw9T4il x])
c "config/boot.rb", "N92-rb-array-q", %q(["BUNDLE_A__B=usr7k:Pw9T4il", "x"])
c "config/boot.rb", "N93-rb-array-sp", %q(["BUNDLE_A__B=usr7k:Pw9 T4il", "x"])
c "config/boot.rb", "N94-rb-env-hash-pair", %q(Process.spawn({ "BUNDLE_A__B" => "usr7k:Pw9T4il" }, "bundle"))
c "config/boot.rb", "N95-rb-env-hash-last", %q(system({ "BUNDLE_A__B" => "usr7k:Pw9T4il" }, "bundle", "install"))
c "config/boot.rb", "N96-rb-env-store", %q(ENV.store("BUNDLE_A__B", "usr7k:Pw9T4il"))
c "config/boot.rb", "N97-rb-env-update", %q(ENV.update("BUNDLE_A__B" => "usr7k:Pw9T4il"))
c "config/boot.rb", "N98-rb-env-merge-kw", %q(ENV.merge!(BUNDLE_A__B: "usr7k:Pw9T4il"))
c "config/boot.rb", "N99-rb-with-env", %q(with_env("BUNDLE_A__B" => "usr7k:Pw9T4il") { run })
c "config/boot.rb", "N100-rb-stub-env", %q(stub_const("ENV", ENV.to_h.merge("BUNDLE_A__B" => "usr7k:Pw9T4il")))
c "config/boot.rb", "N101-rb-yaml-dump", %q(File.write(".bundle/config", "BUNDLE_A__B: usr7k:Pw9T4il\n"))
c "config/boot.rb", "N102-rb-yaml-dump-sq", %q(File.write(".bundle/config", 'BUNDLE_A__B: "usr7k:Pw9T4il"'))
c "config/boot.rb", "N103-rb-yaml-dump-esc", %q(File.write(".bundle/config", "BUNDLE_A__B: \"usr7k:Pw9T4il\"\n"))
c "config/boot.rb", "N104-rb-hash-to-yaml", %q({ "BUNDLE_A__B" => "usr7k:Pw9T4il" }.to_yaml)
c "config/boot.rb", "N105-rb-hash-to-json", %q(JSON.generate("BUNDLE_A__B" => "usr7k:Pw9T4il"))
c "config/boot.rb", "N106-rb-string-fmt", %q(puts "BUNDLE_A__B=%s" % "usr7k:Pw9T4il")
c "config/boot.rb", "N107-rb-bundler-set", %q(Bundler.settings.set_local("gems.example.com", "usr7k:Pw9T4il"))
c "config/boot.rb", "N108-rb-bundler-set-sym", %q(Bundler.settings[:"gems.example.com"] = "usr7k:Pw9T4il")
c "config/boot.rb", "N109-rb-bundler-set-str", %q(Bundler.settings["gems.example.com"] = "usr7k:Pw9T4il")
c "config/boot.rb", "N110-rb-bundler-cfg-cli", %q(Bundler::CLI.start(["config", "set", "gems.example.com", "usr7k:Pw9T4il"]))
c "config/boot.rb", "N111-rb-gemfile-credentials", %q(source "https://gems.example.com" do; end # BUNDLE_A__B=usr7k:Pw9T4il)
c "config/boot.rb", "N112-rb-cmd-array-nospace", %q(system(%w[bundle config set gems.example.com usr7k:Pw9T4il]))
c "config/boot.rb", "N113-rb-cmd-array-q", %q(system('bundle', 'config', 'set', 'gems.example.com', 'usr7k:Pw9T4il'))
c "config/boot.rb", "N114-rb-cmd-array-flag", %q(system("bundle", "config", "set", "--global", "gems.example.com", "usr7k:Pw9T4il"))
c "config/boot.rb", "N115-rb-cmd-array-env", %q(system({"X"=>"1"}, "bundle", "config", "set", "gems.example.com", "usr7k:Pw9T4il"))
c "config/boot.rb", "N116-rb-cmd-array-interp-host", %q(system("bundle", "config", "set", "#{host}", "usr7k:Pw9T4il"))
c "config/boot.rb", "N117-rb-cmd-array-var-host", %q(system("bundle", "config", "set", host, "usr7k:Pw9T4il"))
c "config/boot.rb", "N118-rb-sh-interp-host", %q(sh "bundle config set #{host} usr7k:Pw9T4il")
c "config/boot.rb", "N119-rb-sh-var-host-env", %q(sh "bundle config set gems.example.com #{user}:Pw9T4il")
c "config/boot.rb", "N120-rb-backtick-interp", "`bundle config set gems.example.com \#{u}:Pw9T4il`"
c "config/boot.rb", "N121-rb-exec-exec", %q(exec("bundle", "config", "set", "gems.example.com", "usr7k:Pw9T4il"))
c "config/boot.rb", "N122-rb-sh-no-set", %q(sh "bundle config gems.example.com 'usr7k:Pw9T4il'")
c "config/boot.rb", "N123-rb-cmd-sq-with-dq-inside", %q(sh 'bundle config gems.example.com "usr7k:Pw9T4il"')
c "config/boot.rb", "N124-rb-cmd-2-in-one-str", %q(sh "bundle config a.b usr7k:Pw9 && bundle config c.d T4il")
c "config/boot.rb", "N125-rb-cmd-sq-in-sq-esc", %q(sh 'bundle config a.b \'usr7k:Pw9T4il\'')
c "config/boot.rb", "N126-rb-cmd-sq-sq-sq", %q(sh 'bundle config a.b '\''usr7k:Pw9T4il'\''')
c "config/boot.rb", "N127-rb-heredoc-sh", "sh <<~SH\n  bundle config set a.b usr7k:Pw9T4il\nSH"
c "config/boot.rb", "N128-rb-heredoc-env", "sh <<~SH\n  export BUNDLE_A__B='usr7k:Pw9 T4il'\nSH"
c "config/boot.rb", "N129-rb-heredoc-in-hash", "{\n  'BUNDLE_A__B' => <<~PW,\n    usr7k:Pw9T4il\n  PW\n  'X' => 1 }"
c "config/boot.rb", "N130-rb-heredoc-squiggly-call", "set(BUNDLE_A__B: <<~PW)\n  usr7k:Pw9T4il\nPW"
c "config/boot.rb", "N131-rb-heredoc-tag-quote", "ENV['BUNDLE_A__B'] = <<~\"PW\"\n  usr7k:Pw9T4il\nPW"
c "config/boot.rb", "N132-rb-heredoc-tag-lower", "ENV['BUNDLE_A__B'] = <<~pw\n  usr7k:Pw9T4il\npw"
c "config/boot.rb", "N133-rb-two-heredocs", "ENV['BUNDLE_A__B'] = <<~A + <<~B\n  usr7k:Pw9\nA\n  T4il\nB"
c "config/boot.rb", "N134-rb-heredoc-end-indented", "ENV['BUNDLE_A__B'] = <<-A\n  usr7k:Pw9T4il\n  A\nputs 1"
c "config/boot.rb", "N135-rb-heredoc-not-closed-by-indent", "ENV['BUNDLE_A__B'] = <<A\n  usr7k:Pw9T4il\n  A\nT4il2\nA"
c "bin/setup", "N136-sh-heredoc-env-body", "cat >> ~/.bashrc <<EOF\nexport BUNDLE_A__B=usr7k:Pw9T4il\nEOF"
c "bin/setup", "N137-sh-heredoc-cfg", "cat > ~/.bundle/config <<'EOF'\n---\nBUNDLE_A__B: \"usr7k:Pw9T4il\"\nEOF"
c "bin/setup", "N138-sh-heredoc-cfg-block", "cat > ~/.bundle/config <<'EOF'\nBUNDLE_A__B: >-\n  usr7k:Pw9T4il\nEOF"
c "Dockerfile", "N139-dockerfile-heredoc-copy", "COPY <<EOF /root/.bundle/config\nBUNDLE_A__B: usr7k:Pw9T4il\nEOF"
c "Dockerfile", "N140-dockerfile-heredoc-run-cfg", "RUN <<EOF\ncat > .bundle/config <<X\nBUNDLE_A__B=usr7k:Pw9T4il\nX\nEOF"
c "Dockerfile", "N141-multi-cont-env", "ENV BUNDLE_A__B=usr7k:Pw9T4il \\\n    X=1"
c "Dockerfile", "N142-env-cont-first", "ENV X=1 \\\n    BUNDLE_A__B=usr7k:Pw9T4il"
c "Dockerfile", "N143-env-cont-value", "ENV BUNDLE_A__B=\\\n    usr7k:Pw9T4il"
c "Dockerfile", "N144-env-cont-dq", "ENV BUNDLE_A__B=\"usr7k:Pw9\\\n    T4il\""
c "Dockerfile", "N145-env-multi-two", "ENV BUNDLE_A__B=usr7k \\\n    BUNDLE_C__D=Pw9T4il"
c "Dockerfile", "N146-env-quoted-sp", "ENV BUNDLE_A__B=\"usr7k:Pw9 T4il\" X=1"
c "Dockerfile", "N147-env-sp-form-sp", "ENV BUNDLE_A__B usr7k:Pw9 T4il"
c "Dockerfile", "N148-lower-run", "run bundle config set a.b usr7k:Pw9T4il"
c "Dockerfile", "N149-onbuild", "ONBUILD RUN bundle config set a.b usr7k:Pw9T4il"
c "Dockerfile", "N150-shell-form-json", "RUN [\"sh\", \"-c\", \"bundle config set a.b usr7k:Pw9T4il\"]"
c "Dockerfile", "N151-exec-form-sp", "RUN [ \"bundle\" , \"config\" , \"set\" , \"a.b\" , \"usr7k:Pw9T4il\" ]"
c "Dockerfile", "N152-exec-form-sq-json", "RUN ['bundle', 'config', 'set', 'a.b', 'usr7k:Pw9T4il']"
c "Dockerfile", "N153-exec-form-flag", "RUN [\"bundle\", \"config\", \"set\", \"--global\", \"a.b\", \"usr7k:Pw9T4il\"]"
c "Dockerfile", "N154-exec-form-nl", "RUN [\"bundle\", \"config\", \"set\", \"a.b\", \\\n \"usr7k:Pw9T4il\"]"
c "Dockerfile", "N155-exec-form-esc", "RUN [\"sh\", \"-c\", \"bundle config set a.b \\\"usr7k:Pw9T4il\\\"\"]"
c "Dockerfile", "N156-label", "LABEL cfg=\"BUNDLE_A__B=usr7k:Pw9T4il\""
c "Dockerfile", "N157-build-secret-id", "RUN --mount=type=secret,id=x BUNDLE_A__B=usr7k:Pw9T4il bundle install"
c "Dockerfile", "N158-mount-env", "RUN --mount=type=cache,target=/x BUNDLE_A__B=\"usr7k:Pw9T4il\" bundle install"
c "config/boot.rb", "H01-apostrophe-comment-sq", %q(# don't forget: BUNDLE_A__B='usr7k:Pw9T4il')
c "config/boot.rb", "H02-apostrophe-comment-bare", %q(# don't forget: ENV["BUNDLE_A__B"] = "usr7k:Pw9T4il")
c "README.md", "H03-prose-apostrophe-span", "Don't forget `BUNDLE_A__B=usr7k:Pw9T4il`."
c "README.md", "H04-prose-apostrophe-sq", "Don't forget BUNDLE_A__B='usr7k:Pw9T4il' in CI."
c "README.md", "H05-prose-apostrophe-dq", "It's easy: BUNDLE_A__B=\"usr7k:Pw9T4il\""
c "bin/setup", "H06-apos-then-env", %q(echo "it's set"; export BUNDLE_A__B='usr7k:Pw9T4il')
c "bin/setup", "H07-dq-unbalanced-then-sq", %q(# say "hi; export BUNDLE_A__B='usr7k:Pw9T4il')
c "docker-compose.yml", "H08-yaml-comment-apos", "# don't commit: \nBUNDLE_A__B: 'usr7k:Pw9T4il'"
c "docker-compose.yml", "H09-yaml-key-apos", %q(description: "it's here"; BUNDLE_A__B: usr7k:Pw9T4il)
c "Dockerfile", "H10-dockerfile-comment", %q(# it's ok. ENV BUNDLE_A__B='usr7k:Pw9T4il')
c "config/boot.rb", "H11-str-with-apos-before", %q(puts "it's"; ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il')
c "config/boot.rb", "H12-backtick-before", %q(`ls`; ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il')
c "config/boot.rb", "H13-odd-backtick", %q(# `x; ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il')
c "config/boot.rb", "H14-odd-dq-before-dq", %q(# say "hi; ENV["BUNDLE_A__B"] = "usr7k:Pw9T4il")
c "bin/setup", "H15-sq-value-after-apos", %q(# don't. bundle config set a.b 'usr7k:Pw9T4il')
c "bin/setup", "H16-dq-value-after-apos", %q(# don't. bundle config set a.b "usr7k:Pw9T4il")
c "bin/setup", "H17-bare-after-apos", %q(# don't. bundle config set a.b usr7k:Pw9T4il)
c "bin/setup", "H18-bare-sp-after-apos", %q(# don't. BUNDLE_A__B=usr7k:Pw9T4il bundle install)
c "bin/setup", "H19-apos-after-value-pre", %q(BUNDLE_A__B=usr7k:Pw9T4il # don't)
c "config/boot.rb", "H20-esc-apos-before", %q(puts 'it\'s'; ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il')
c "bin/setup", "H21-sq-bs-before", %q(echo 'a\' ; export BUNDLE_A__B='usr7k:Pw9T4il')
c "config/boot.rb", "H22-regex-quote", %q(x =~ /"/ ; ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il')
c "config/boot.rb", "H23-char-lit", %q(c = ?" ; ENV['BUNDLE_A__B'] = 'usr7k:Pw9T4il')
c "bin/setup", "H24-ansi-esc", %q(echo $'it\'s'; export BUNDLE_A__B='usr7k:Pw9T4il')
# --- found while fixing the forms above
c "bin/setup", "Z01-sq-bs-then-dq-host", %q(echo 'a\'"BUNDLE_A__B=usr7k:Pw9 T4il")
c "bin/setup", "Z02-command-in-kept-word", %q(export BUNDLE_A__B="$(bundle config set a.b usr7k:Pw9T4il)")
c "Dockerfile", "Z03-cfg-in-substitution", %q(ENV BUNDLE_A__B=$(bundle config set a.b "usr7k:Pw9 T4il"))
c "config/boot.rb", "Z04-plus-keeps-operator", %q(ENV["BUNDLE_A__B"] = creds.user + ":" + "Pw9T4il")
c "bin/setup", "Z05-heredoc-shell", "export BUNDLE_A__B=<<A\nusr7k:Pw9\nT4il\nA"
c "config/boot.rb", "Z07-percent-multiline", "ENV['BUNDLE_A__B'] = %Q(usr7k:\#{x}Pw9\nT4il)"
c "Dockerfile", "Z08-cfg-header-split-twice", "RUN bundle config \\\n  set \\\n  --global \\\n  gems.example.com \\\n  usr7k:Pw9T4il"
c "config/boot.rb", "R5-01-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] ||\n  'Pw9T4il'"
c "config/boot.rb", "R5-02-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] +\n  'usr7k:Pw9T4il'"
c "config/boot.rb", "R5-03-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] \\\n  'usr7k:Pw9T4il'"
c "config/boot.rb", "R5-04-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] or\n  'Pw9T4il'"
c "config/boot.rb", "R5-05-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] ? ENV['X'] :\n  'Pw9T4il'"
c "config/boot.rb", "R5-06-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = x ?\n  'a' : 'usr7k:Pw9T4il'"
c "config/boot.rb", "R5-07-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = foo\n  .bar('usr7k:Pw9T4il')"
c "config/boot.rb", "R5-08-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X']\n  .sub('a', 'Pw9T4il')"
c "config/boot.rb", "R5-09-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = x\n  &.y('Pw9T4il')"
c "config/boot.rb", "R5-10-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['A']\n  .to_s + 'usr7k:Pw9T4il'"
c "config/boot.rb", "R5-11-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = X # ok\n  .y('usr7k:Pw9T4il')"
c "config/boot.rb", "R5-12-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = x::Y\n'usr7k:Pw9T4il'"
c "config/boot.rb", "R5-13-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV.fetch('X') do\n  'Pw9T4il'\nend"
c "config/boot.rb", "R5-14-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = begin\n  'Pw9T4il'\nend"
c "config/boot.rb", "R5-15-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = if x\n 'Pw9T4il'\nend"
c "config/boot.rb", "R5-16-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = case x\n when 1 then 'Pw9T4il'\nend"
c "config/boot.rb", "R5-17-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = x.map do |y|\n 'Pw9T4il'\nend"
c "config/boot.rb", "R5-18-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] &&\n  'Pw9T4il'"
c "config/boot.rb", "R5-19-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] and\n  'Pw9T4il'"
c "config/boot.rb", "R5-20-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] ||\n\n  'Pw9T4il'"
c "config/boot.rb", "R5-21-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = foo(ENV['X'],\n  'Pw9T4il')"
c "config/boot.rb", "R5-22-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = [ENV['X'],\n  'Pw9T4il']"
c "config/boot.rb", "R5-23-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = {a: ENV['X'],\n  b: 'Pw9T4il'}"
c "config/boot.rb", "R5-24-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = :Pw9T4il"
c "config/boot.rb", "R5-25-ruby-continued", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = -> { 'Pw9T4il' }.call"
c "Rakefile", "R5-26-rakefile-interpolation", "sh \"bundle config set gems.example.com \#{ENV['X']}usr7k:Pw9T4il\""
c "Rakefile", "R5-27-rakefile-interpolation", "sh \"bundle config set gems.example.com usr7k:Pw9T4il\#{ENV['X']}\""
c "Rakefile", "R5-28-rakefile-interpolation", "sh \"bundle config set gems.example.com \#{ENV['U']}:\#{ENV['T']}:Pw9T4il\""
c "Dockerfile", "R5-29-docker-continuation", "RUN bundle config set gems.example.com \\\n  # c\n  usr7k:Pw9T4il"
c "Dockerfile", "R5-30-docker-continuation", "RUN bundle config set gems.example.com \\\n\n  usr7k:Pw9T4il"
c "Dockerfile", "R5-31-docker-continuation", "RUN bundle config set gems.example.com \\\n\n\n\n\n\n  usr7k:Pw9T4il"
c "Dockerfile", "R5-32-docker-continuation", "RUN bundle config set gems.example.com \\\t\n  usr7k:Pw9T4il"
c "Dockerfile", "R5-33-docker-continuation", "RUN bundle config set gems.example.com \\ \n  usr7k:Pw9T4il"
c "Dockerfile", "R5-34-docker-continuation", "RUN bundle config set gems.example.com \\\r\n  usr7k:Pw9T4il"
c "Dockerfile", "R5-35-docker-continuation", "RUN bundle config set gems.example.com \\\n  usr7k:Pw9T4il"
c "Dockerfile", "R5-36-docker-continuation", "RUN bundle config set gems.example.com \\\n  # c\n\n  # d\n  usr7k:Pw9T4il"
