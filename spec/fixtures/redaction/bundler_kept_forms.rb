# frozen_string_literal: true

# Code and prose that names a gem server setting without holding its credential, one per line: k(file kind, text).
# The redaction must leave each as it is.
k "config/boot.rb", %q(ENV["BUNDLE_PATH"] = "vendor/bundle")
k "config/boot.rb", %q(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__))
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV["GEM_CREDS"] if ENV["GEM_CREDS"])
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV["GEM_CREDS"]; puts "done")
k "config/boot.rb", %q(raise "BUNDLE_GEMS__EXAMPLE__COM is not set" unless ENV["BUNDLE_GEMS__EXAMPLE__COM"])
k "config/boot.rb", %q(abort "set BUNDLE_GEMS__EXAMPLE__COM first")
k "config/boot.rb", %q(puts "BUNDLE_GEMS__EXAMPLE__COM=#{ENV['BUNDLE_GEMS__EXAMPLE__COM'] ? 'set' : 'unset'}")
k "config/boot.rb", %q(if ENV["BUNDLE_GEMS__EXAMPLE__COM"] == "x" then run end)
k "config/boot.rb", %q(x = ENV["BUNDLE_GEMS__EXAMPLE__COM"]; y = 1)
k "config/boot.rb", %q(h = { "BUNDLE_GEMS__EXAMPLE__COM" => nil, "OTHER" => "x" })
k "config/boot.rb", %q(h = { "BUNDLE_GEMS__EXAMPLE__COM" => ENV["X"], "OTHER" => "keepme" })
k "config/boot.rb", %q(h = { "BUNDLE_GEMS__EXAMPLE__COM" => "", "OTHER" => "keepme" })
k "config/boot.rb", %q(ENV.delete("BUNDLE_GEMS__EXAMPLE__COM"))
k "config/boot.rb", %q(ENV.key?("BUNDLE_GEMS__EXAMPLE__COM") ? log("yes") : log("no"))
k "config/boot.rb", %q(ENV.fetch("BUNDLE_GEMS__EXAMPLE__COM", nil))
k "config/boot.rb", %q(ENV.fetch("BUNDLE_GEMS__EXAMPLE__COM", "")) 
k "config/boot.rb", %q(ENV.fetch("BUNDLE_GEMS__EXAMPLE__COM") { raise "missing" })
k "config/boot.rb", %q(env_names = %w[BUNDLE_GEMS__EXAMPLE__COM BUNDLE_PATH])
k "config/boot.rb", %q(NAMES = ["BUNDLE_GEMS__EXAMPLE__COM", "BUNDLE_PATH"].freeze)
k "config/boot.rb", %q(KEY = "BUNDLE_GEMS__EXAMPLE__COM")
k "config/boot.rb", %q(KEY = "BUNDLE_GEMS__EXAMPLE__COM".freeze)
k "config/boot.rb", %q(expect(ENV["BUNDLE_GEMS__EXAMPLE__COM"]).to eq("x"))
k "config/boot.rb", %q(allow(ENV).to receive(:[]).with("BUNDLE_GEMS__EXAMPLE__COM").and_return(nil))
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = nil)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "$GEM_CREDS")
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = Settings.gems.creds.to_s)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = Rails.application.credentials.gems.to_s)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = creds)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = creds_for(host))
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = @creds)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = CREDS)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = "#{user}:#{pass}")
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = [user, pass].join(":"))
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV["U"] + ":" + ENV["P"])
k "Dockerfile", %q(ENV BUNDLE_GEMS__EXAMPLE__COM=$GEM_CREDS)
k "Dockerfile", %q(ENV BUNDLE_GEMS__EXAMPLE__COM=${GEM_CREDS})
k "Dockerfile", %q(ENV BUNDLE_GEMS__EXAMPLE__COM="")
k "Dockerfile", %q(ARG BUNDLE_GEMS__EXAMPLE__COM)
k "Dockerfile", %q(ENV BUNDLE_GEMS__EXAMPLE__COM=)
k "Dockerfile", %q(ENV BUNDLE_PATH=/usr/local/bundle BUNDLE_JOBS=4 BUNDLE_RETRY=3)
k "Dockerfile", %q(ENV BUNDLE_PATH="/usr/local/bundle" BUNDLE_GEMS__EXAMPLE__COM=$X)
k "Dockerfile", %q(RUN bundle config set --global frozen true && bundle install)
k "Dockerfile", %q(RUN bundle config set --local path vendor/bundle)
k "Dockerfile", %q(RUN bundle config set --local without 'development test')
k "Dockerfile", %q(RUN bundle config set --local deployment true && bundle install --jobs 4)
k "Dockerfile", %q(RUN bundle config set gems.example.com "$GEM_CREDS" && bundle install)
k "Dockerfile", %q(RUN --mount=type=secret,id=creds bundle config set gems.example.com "$(cat /run/secrets/creds)")
k "Dockerfile", %q(RUN bundle config unset gems.example.com)
k "Dockerfile", %q(RUN bundle config get gems.example.com)
k "Dockerfile", %q(RUN bundle config list)
k "Dockerfile", %q(RUN bundle config set build.nokogiri --use-system-libraries)
k "Dockerfile", %q(RUN bundle config set build.pg "--with-pg-config=/usr/bin/pg_config")
k "Dockerfile", %q(RUN bundle config set mirror.https://rubygems.org https://mirror.example.com)
k "Dockerfile", %q(RUN bundle config set local.rails /src/rails)
k "Dockerfile", %q(RUN bundle config set --global github.https true)
k "Dockerfile", %q(RUN bundle config set gem.mit false && bundle config set gem.coc false)
k "Dockerfile", %q(RUN bundle config set gem.github_username me)
k "Dockerfile", %q(RUN bundle config set specific_platform true)
k "Dockerfile", %q(RUN bundle config set app_config /app/.bundle)
k "Dockerfile", %q(RUN bundle config set ssl_verify_mode 0)
k "Dockerfile", %q(RUN bundle config set ssl_ca_cert /etc/ssl/ca.pem)
k "Dockerfile", %q(RUN bundle config set force_ruby_platform true)
k "Dockerfile", %q(RUN bundle config set cache_all true)
k "Dockerfile", %q(RUN bundle config set bin bin)
k "Dockerfile", %q(RUN bundle config set silence_root_warning true)
k "Dockerfile", %q(RUN bundle config set gems.example.com:8080 "$X")
k "Dockerfile", %q(RUN bundle config set --global frozen 1 && echo "BUNDLE_PATH=x")
k "Dockerfile", %q(RUN bundle exec rake db:migrate && bundle config list)
k "Dockerfile", %q(RUN echo "bundle config is set" && bundle install)
k "Dockerfile", %q(RUN bundle config set --local path 'vendor/bundle' ; echo ok)
k ".github/workflows/ci.yml", "env:\n  BUNDLE_GEMS__EXAMPLE__COM: ${{ secrets.GEM_CREDS }}\n  OTHER: keepme"
k ".github/workflows/ci.yml", "env:\n  BUNDLE_GEMS__EXAMPLE__COM: \"${{ secrets.GEM_CREDS }}\"\n  OTHER: keepme"
k ".github/workflows/ci.yml", "env:\n  BUNDLE_WITHOUT: development:test\n  BUNDLE_JOBS: 4\n  BUNDLE_RETRY: 3\n  BUNDLE_PATH: vendor/bundle"
k ".github/workflows/ci.yml", "env:\n  BUNDLE_GEMS__EXAMPLE__COM: |\n    ${{ secrets.X }}\n  OTHER: keepme"
k ".github/workflows/ci.yml", "  run: echo \"BUNDLE_GEMS__EXAMPLE__COM=${{ secrets.X }}\" >> $GITHUB_ENV"
k ".github/workflows/ci.yml", "  run: echo \"BUNDLE_WITHOUT=development test\" >> $GITHUB_ENV"
k ".github/workflows/ci.yml", "- run: bundle config set --local without 'development test'"
k ".bundle/config", "---\nBUNDLE_PATH: \"vendor/bundle\"\nBUNDLE_WITHOUT: \"development:test\"\nBUNDLE_JOBS: \"4\""
k ".bundle/config", "---\nBUNDLE_GEMS__EXAMPLE__COM: \"\"\nBUNDLE_PATH: vendor"
k ".bundle/config", "BUNDLE_BUILD__NOKOGIRI: \"--use-system-libraries\"\nBUNDLE_PATH: vendor"
k ".bundle/config", "BUNDLE_MIRROR__HTTPS://RUBYGEMS.ORG/: \"https://mirror.example.com\"\nBUNDLE_PATH: vendor"
k ".bundle/config", "BUNDLE_LOCAL__RAILS: \"/src/rails\"\nBUNDLE_PATH: vendor"
k ".bundle/config", "BUNDLE_GEM__MIT: \"false\"\nBUNDLE_GEM__COC: \"false\""
k ".bundle/config", "BUNDLE_GITHUB__HTTPS: \"true\"\nBUNDLE_PATH: vendor"
k ".bundle/config", "BUNDLE_GEMS__EXAMPLE__COM: !ruby/object:String x"
k ".bundle/config", "BUNDLE_PATH: vendor/bundle # keep this"
k ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=\nBUNDLE_PATH=vendor"
k ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=changeme\nBUNDLE_PATH=vendor"
k ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=user:password\nBUNDLE_PATH=vendor"
k ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=<your-credentials>\nBUNDLE_PATH=vendor"
k ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=xxx\nBUNDLE_PATH=vendor"
k ".env.example", "# BUNDLE_GEMS__EXAMPLE__COM=user:pass\nBUNDLE_PATH=vendor"
k ".env.example", "BUNDLE_GEMS__EXAMPLE__COM=${GEM_CREDS}"
k ".env", "BUNDLE_GEMS__EXAMPLE__COM= # set me"
k ".env", "BUNDLE_GEMS__EXAMPLE__COM=\nOTHER=keepme"
k "bin/setup", %q(export BUNDLE_PATH="vendor" && bundle install)
k "bin/setup", %q(export BUNDLE_GEMS__EXAMPLE__COM="$GEM_CREDS" && bundle install)
k "bin/setup", %q(export BUNDLE_GEMS__EXAMPLE__COM="$(op read op://x/y)" && bundle install)
k "bin/setup", %q(export BUNDLE_GEMS__EXAMPLE__COM=`op read op://x/y`)
k "bin/setup", %q(export BUNDLE_GEMS__EXAMPLE__COM="${GEM_CREDS:?set GEM_CREDS}")
k "bin/setup", %q(export BUNDLE_GEMS__EXAMPLE__COM="${GEM_CREDS:-}")
k "bin/setup", %q(unset BUNDLE_GEMS__EXAMPLE__COM)
k "bin/setup", %q(echo "BUNDLE_GEMS__EXAMPLE__COM is $BUNDLE_GEMS__EXAMPLE__COM")
k "bin/setup", %q([ -n "$BUNDLE_GEMS__EXAMPLE__COM" ] && echo set)
k "bin/setup", %q([ -z "${BUNDLE_GEMS__EXAMPLE__COM}" ] && echo unset)
k "bin/setup", %q(if [ "$BUNDLE_GEMS__EXAMPLE__COM" = "" ]; then echo none; fi)
k "bin/setup", %q(test "$BUNDLE_GEMS__EXAMPLE__COM" = "x" || exit 1)
k "bin/setup", %q(bundle config get gems.example.com | grep -q "set" && echo ok)
k "bin/setup", %q(bundle config --parseable | grep gems.example.com)
k "bin/setup", %q(bundle config set path vendor/bundle; bundle install)
k "bin/setup", %q(bundle config set --local path "vendor/bundle" && bundle install)
k "bin/setup", %q(bundle config set --local without "development test" || true)
k "bin/setup", %q(bundle config path vendor/bundle)
k "bin/setup", %q(bundle config set jobs 4 && bundle config set retry 3)
k "bin/setup", %q(bundle config set gems.example.com "$GEM_CREDS" && echo "configured gems.example.com")
k "bin/setup", %q(bundle config set gems.example.com $GEM_CREDS >/dev/null 2>&1)
k "bin/setup", %q(bundle config set gems.example.com "$GEM_CREDS" 2>&1 | tee log)
k "bin/setup", %q(bundle config set gems.example.com "$GEM_CREDS"; bundle install)
k "bin/setup", %q(bundle config set gems.example.com "$GEM_CREDS" || exit 1)
k "bin/setup", %q(bundle config set gems.example.com "$GEM_CREDS" # per environment)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV.fetch("GEM_CREDS") # comes from CI)
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV["GEM_CREDS"] unless ENV["BUNDLE_GEMS__EXAMPLE__COM"])
k "config/boot.rb", %q(ENV["BUNDLE_GEMS__EXAMPLE__COM"] = ENV["GEM_CREDS"] if ENV["GEM_CREDS"] && !ENV["BUNDLE_GEMS__EXAMPLE__COM"])
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: ${GEM_CREDS}\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  - BUNDLE_GEMS__EXAMPLE__COM=${GEM_CREDS}\n  - OTHER=keepme"
k "docker-compose.yml", "environment:\n  - BUNDLE_GEMS__EXAMPLE__COM\n  - OTHER=keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM:\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: null\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: ~\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: \"\"\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: *creds\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: !reset null\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: <<: *x\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: ${GEM_CREDS:-}\n  OTHER: keepme"
k "docker-compose.yml", "environment:\n  BUNDLE_GEMS__EXAMPLE__COM: ${GEM_CREDS:?required}\n  OTHER: keepme"
k "docker-compose.yml", "# BUNDLE_GEMS__EXAMPLE__COM: user:pass is set in CI\nservices:\n  web: {}"
k "docker-compose.yml", "services:\n  web:\n    environment:\n      BUNDLE_PATH: /bundle\n      BUNDLE_GEMS__EXAMPLE__COM: ${GEM_CREDS}\n    ports: [\"3000:3000\"]"
k "app.json", %q({"env": {"BUNDLE_GEMS__EXAMPLE__COM": {"required": true}, "OTHER": "keepme"}})
k "app.json", %q({"env": {"BUNDLE_GEMS__EXAMPLE__COM": {"description": "creds", "required": true}}})
k "app.json", %q({"env": {"BUNDLE_GEMS__EXAMPLE__COM": {"generator": "secret"}}})
k "app.json", %q({"env": {"BUNDLE_GEMS__EXAMPLE__COM": {"value": ""}, "OTHER": "keepme"}})
k "app.json", %q({"env": {"BUNDLE_GEMS__EXAMPLE__COM": null, "OTHER": "keepme"}})
k "app.json", %q({"BUNDLE_PATH": "vendor", "BUNDLE_GEMS__EXAMPLE__COM": "", "OTHER": "keepme"})
k "app.json", %q({"BUNDLE_GEMS__EXAMPLE__COM": true, "OTHER": "keepme"})
k "app.json", %q({"BUNDLE_GEMS__EXAMPLE__COM": 5, "OTHER": "keepme"})
k "app.json", %q({"BUNDLE_GEMS__EXAMPLE__COM": ["a"], "OTHER": "keepme"})
k "app.json", %q({"BUNDLE_GEMS__EXAMPLE__COM": {"x": "keepme"}, "OTHER": "keepme"})
k "app.json", %q({"BUNDLE_GEMS__EXAMPLE__COM": "${GEM_CREDS}", "OTHER": "keepme"})
k "config.toml", %q(BUNDLE_GEMS__EXAMPLE__COM = "${GEM_CREDS}")
k "config.toml", %q(BUNDLE_GEMS__EXAMPLE__COM = true)
k "config.toml", %q(BUNDLE_GEMS__EXAMPLE__COM = 5 # n)
k "values.yaml", "BUNDLE_GEMS__EXAMPLE__COM: {{ .Values.creds | quote }}\nOTHER: keepme"
k "values.yaml", "BUNDLE_GEMS__EXAMPLE__COM: {{ .Values.creds }}\nOTHER: keepme"
k "values.yaml", "BUNDLE_GEMS__EXAMPLE__COM: ''\nOTHER: keepme"
k "README.md", "Set `BUNDLE_GEMS__EXAMPLE__COM` to `user:password`."
k "README.md", "Set `BUNDLE_GEMS__EXAMPLE__COM` before running."
k "README.md", "Set BUNDLE_GEMS__EXAMPLE__COM before running, then call bundle install."
k "README.md", "- `BUNDLE_GEMS__EXAMPLE__COM`: your gem server credentials, as user:token"
k "README.md", "Use `bundle config set gems.example.com USER:TOKEN` to log in."
k "README.md", "Use `bundle config set gems.example.com <user>:<token>` to log in."
k "README.md", "Use `bundle config set gems.example.com $USER:$TOKEN`."
k "README.md", "Run `bundle config` to see settings, and `bundle config set path vendor` to change one."
k "README.md", "Run bundle config set path vendor; then bundle install."
k "README.md", "The `bundle config set jobs 4` flag speeds installs, `BUNDLE_JOBS=4` too."
k "README.md", "BUNDLE_GEMS__EXAMPLE__COM is read by Bundler (see the docs)."
k "README.md", "BUNDLE_GEMS__EXAMPLE__COM: see below"
k "README.md", "Example: BUNDLE_GEMS__EXAMPLE__COM=user:password bundle install"
k "README.md", "```sh\nexport BUNDLE_GEMS__EXAMPLE__COM=\"user:password\"\n```"
k "README.md", "```sh\nexport BUNDLE_GEMS__EXAMPLE__COM=\"$GEM_CREDS\"\n```"
k "lib/tasks/x.rake", %q(task :check do puts "BUNDLE_GEMS__EXAMPLE__COM present" if ENV["BUNDLE_GEMS__EXAMPLE__COM"] end)
k "lib/tasks/x.rake", %q(warn "BUNDLE_GEMS__EXAMPLE__COM, BUNDLE_PATH missing")
k "lib/tasks/x.rake", %q(%w[BUNDLE_GEMS__EXAMPLE__COM BUNDLE_PATH].each { |n| puts n })
k "lib/tasks/x.rake", %q(sh "echo BUNDLE_GEMS__EXAMPLE__COM && echo ok")
k "lib/tasks/x.rake", %q(sh "bundle config set gems.example.com #{ENV.fetch('GEM_CREDS')} && echo ok")
k "lib/tasks/x.rake", %q(sh "bundle config set gems.example.com #{creds} && echo ok")
k "lib/tasks/x.rake", %q(sh "bundle config set --local path vendor && echo ok")
k "lib/x.rb", %q(def bundle_config(host, creds) = system("bundle", "config", "set", host, creds))
k "lib/x.rb", %q(BUNDLE_VARS = %w[BUNDLE_GEMS__EXAMPLE__COM].freeze)
k "lib/x.rb", %q(BUNDLE_VAR = "BUNDLE_GEMS__EXAMPLE__COM")
k "lib/x.rb", %q(@env = { "BUNDLE_GEMS__EXAMPLE__COM" => @creds, "OTHER" => "keepme" })
k "lib/x.rb", %q(@env = { "BUNDLE_GEMS__EXAMPLE__COM": @creds, "OTHER": "keepme" })
k "lib/x.rb", %q(env["BUNDLE_GEMS__EXAMPLE__COM"] = @creds if @creds)
k "lib/x.rb", %q(expect(env).to include("BUNDLE_GEMS__EXAMPLE__COM" => "x"))
k "spec/x_spec.rb", %q(expect(ENV["BUNDLE_GEMS__EXAMPLE__COM"]).to eq("user:pass"))
k "config/boot.rb", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X']\n  .strip\n  .freeze"
k "config/boot.rb", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X'] ||\n  ENV['Y']"
k "config/boot.rb", "ENV['BUNDLE_GEMS__EXAMPLE__COM'] = ENV['X']\n# next\n\nputs ENV['Y']"
k "Dockerfile", "RUN bundle config set gems.example.com $TOKEN \\\n  # why\n\n  && bundle install"
