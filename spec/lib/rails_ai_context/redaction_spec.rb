# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Redaction do
  # What the read tools emit is source an agent will edit, so only a string
  # literal is ever a value here: one under a secret-named key, or one shaped
  # like a credential. Code is never rewritten. Every value below is fake.
  describe ".redact_source_line" do
    def redact(line, path: nil)
      described_class.redact_source_line(line, path: path)
    end

    let(:jwt) { "eyJhbGciOiJub25lIn0.eyJzdWIiOiIxMjM0NTY3ODkwIn0." }
    let(:random) { "q8Zr2LmX0vB7tYp4Wk1Nd6Hs3Jf9Gc5E" }

    it "filters a literal under a secret-named key, in every shape" do
      expect(redact(%(password = "hunter2x"))).to eq(%(password = "[FILTERED]"))
      expect(redact(%(  api_key: 'abc123def'))).to eq(%(  api_key: '[FILTERED]'))
      expect(redact(%("api_key" => 'abc123def'))).to eq(%("api_key" => '[FILTERED]'))
      expect(redact(%(SECRET_TOKEN = "abc12345"))).to eq(%(SECRET_TOKEN = "[FILTERED]"))
      expect(redact(%(secret_key_base: "0f0f0f0f"), path: "config/x.yml")).to eq(%(secret_key_base: "[FILTERED]"))
    end

    # A secret need not mix letters and digits; under a secret-named key a
    # plain literal is filtered unless it is clearly something else.
    # A setter on a receiver is the Rails way to set most secrets, and the name
    # after a dot is still the key.
    it "filters a literal assigned through a setter" do
      [
        %(config.secret_key_base = 'a1b2c3d4e5f6a7b8'),
        %(Devise.secret_key = 'a1b2c3d4e5f6a7b8'),
        %(config.pepper = 'a1b2c3d4e5f6a7b8'),
        %(config.api_key = 'a1b2c3d4e5f6a7b8'),
        %(Twilio.auth_token = 'a1b2c3d4e5f6a7b8'),
        %(user.password = 'a1b2c3d4e5f6a7b8'),
        %(Rails.application.credentials.secret_key_base = 'a1b2c3d4e5f6a7b8')
      ].each { |line| expect(redact(line)).to eq(line.sub(/'[^']*'\z/, "'[FILTERED]'")) }
    end

    # `your-api-key` is a placeholder; `enterprise...` only starts with `enter`.
    it "reads a placeholder prefix only as a whole word" do
      expect(redact(%(api_key: "enterprise9f8e7d6c"))).to eq(%(api_key: "[FILTERED]"))
      expect(redact(%(api_key: "changelog2026ab"))).to eq(%(api_key: "[FILTERED]"))
      expect(redact(%(api_key: "your-api-key"))).to eq(%(api_key: "your-api-key"))
      expect(redact(%(api_key: "change_me_later"))).to eq(%(api_key: "change_me_later"))
    end

    # Seed and spec passwords are often six or seven characters, and a PIN is
    # four: under a password-type key four is enough. Other secret keys keep
    # eight, so `credentials: 'include'` stays.
    it "filters a short literal under a password-type key" do
      expect(redact(%(password: 'hunter2'))).to eq(%(password: '[FILTERED]'))
      expect(redact(%(user.passwd = "s3cr3t"))).to eq(%(user.passwd = "[FILTERED]"))
      expect(redact(%(pin: "8392"))).to eq(%(pin: "[FILTERED]"))
      # A passphrase is words, so a space does not make it a message.
      expect(redact(%(passphrase: "open sesame"))).to eq(%(passphrase: "[FILTERED]"))
      expect(redact(%(pass: 'letmein'))).to eq(%(pass: '[FILTERED]'))
      expect(redact(%(password: 'abc'))).to eq(%(password: 'abc'))
      expect(redact(%(credentials: 'include'))).to eq(%(credentials: 'include'))
      expect(redact(%(pinned: 'yes please'))).to eq(%(pinned: 'yes please'))
    end

    # A licence key, a card-shaped token and an all-capitals secret are not
    # versions or env names, and under a password key a word-joined value is
    # the password a seed file writes.
    it "filters a secret that only resembles a version, an env name or a name" do
      expect(redact(%(api_key: "ABCD-EFGH-IJKL-MNOP"))).to eq(%(api_key: "[FILTERED]"))
      expect(redact(%(token = "1234-5678-9012-3456"))).to eq(%(token = "[FILTERED]"))
      expect(redact("secret: ABCDEFGH_IJKLMNOP", path: "config/x.yml")).to eq("secret: [FILTERED]")
      expect(redact(%(password: "admin_password"))).to eq(%(password: "[FILTERED]"))
      [
        %(token_version: "v2-3"),
        %(api_key_released: "2.4.1"),
        %(API_KEY_ENV = "_DISCOURSE_API"),
        %(sign_in_token: 'sign_in_token')
      ].each { |line| expect(redact(line)).to eq(line) }
    end

    # Shell, Dockerfile, compose and env files write a secret unquoted, as
    # `NAME=value` with no space around the `=`; Ruby never does.
    it "filters an unquoted NAME=value secret" do
      hex = "3b" * 20
      expect(redact("APP_SECRET_TOKEN=#{hex}", path: "docker/secrets.env")).to eq("APP_SECRET_TOKEN=[FILTERED]")
      expect(redact("      - SECRET_KEY_BASE=#{hex}", path: "docker-compose.yml")).to eq("      - SECRET_KEY_BASE=[FILTERED]")
      expect(redact("ENV SECRET_KEY_BASE=#{hex} RAILS_ENV=production", path: "Dockerfile"))
        .to eq("ENV SECRET_KEY_BASE=[FILTERED] RAILS_ENV=production")
      expect(redact("export STRIPE_SECRET_KEY=sk9f8e7d6c5b4a", path: "bin/setup")).to eq("export STRIPE_SECRET_KEY=[FILTERED]")
      expect(redact("DB_PASSWORD=hunter2 \\", path: "Dockerfile")).to eq("DB_PASSWORD=[FILTERED] \\")
    end

    it "replaces only the value of a NAME=value inside a string, URL or comment" do
      jwt = "pk.#{"eyJ1Ijoiam9obiJ9" * 3}.Xk2mQ9pLw7Rt"
      expect(redact(%Q~L.tileLayer('https://api.mapbox.com/tiles/{z}/{x}/{y}?access_token=#{jwt}', {~))
        .to eq(%Q~L.tileLayer('https://api.mapbox.com/tiles/{z}/{x}/{y}?access_token=[FILTERED]', {~)
      expect(redact(%Q(get "/api?token=#{jwt}&page=2", params: {})))
        .to eq(%Q(get "/api?token=[FILTERED]&page=2", params: {}))
      expect(redact(%Q(#     - "ELASTIC_PASSWORD=Xk2mQ9pLw7Rt # the user is elastic"), path: "docker-compose.yml"))
        .to eq(%Q(#     - "ELASTIC_PASSWORD=[FILTERED] # the user is elastic"))
      expect(redact(%Q('Crypto-Key' => 'salt=Xk2mQ9pLw7RtZ4;p256ecdsa=abc',)))
        .to eq(%Q('Crypto-Key' => 'salt=[FILTERED];p256ecdsa=abc',))
    end

    it "leaves a query value, setter, lookbehind or interpolation that is not a secret byte for byte" do
      [
        %q~assert_equal "/government/foo?token=123&utm_source=heading", Edition.new.append_url_options("/government/foo", token: "123")~,
        %q~expect(config).to receive(:openai_api_key=).with(nil)~,
        %q~allow(user).to receive(:password=)~,
        %q~encoded_id_token = response.location[/(?<=id_token=)[^&]+/]~,
        %q~token = response.location[/(?<!access_token=)[^&]+/]~,
        %q(get "/health/api-key-tester?api_key=#{app.api_key}"),
        %q(visit "/orders/1?token=#{order.token}&locale=en"),
        %q(# https://slack.com/api/usergroups.list?token=[TOKEN]),
        %q(# https://backend.demo.taler.net/orders/2026..?token=S3Q..),
        %q~def password=(value)~,
        %q({"@context":"https://example.org","@type":"x:Offer","id":"a@b"}),
        %q("ostatus":"http://ostatus.org#","toot":"http://joinmastodon.org/ns#","x":"y@z")
      ].each { |line| expect(redact(line)).to eq(line) }
    end

    it "leaves an env reference, an ERB value and Ruby code alone" do
      [
        "RAILS_MASTER_KEY=${RAILS_MASTER_KEY}",
        "SECRET_KEY_BASE=$SECRET_KEY_BASE",
        "SECRET_KEY_BASE=<%= ENV['SECRET_KEY_BASE'] %>",
        "SECRET_KEY_BASE=",
        "token = params[:token]",
        "user.password=params[:password]",
        # Discourse's User#password= and Huginn's option placeholder.
        "def password=(pw)",
        "'password' => 'your.password',",
        %(url = "https://x.test/?token=\#{token}")
      ].each { |line| expect(redact(line)).to eq(line) }
    end

    # Forem's user_spec shows `password_confirmation: "newpassword123"` beside
    # a filtered `password:`; a confirmation holds the same secret.
    it "filters every key that holds a password" do
      [
        %(password_confirmation: "newpassword123"),
        %(current_password: "oldpassword123"),
        %(new_password: "newpassword123"),
        %(old_password: "oldpassword123"),
        %(password_digest: "$2a$12$abcdefghijklmnopqrstuv")
      ].each { |line| expect(redact(line)).to eq(line.sub(/"[^"]*"\z/, %("[FILTERED]"))) }
    end

    # An example file often holds real values, so only a plain placeholder is kept there.
    it "filters a real-looking value in an example file and keeps a placeholder" do
      random = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a).cycle.take(86).join
      expect(redact("JWT_HMAC_SECRET: #{random}", path: "config/x.example.yml")).to eq("JWT_HMAC_SECRET: [FILTERED]")
      expect(redact(%(api_key: "a1b2c3d4e5f6a7b8c9"), path: "config/settings.sample.rb")).to eq(%(api_key: "[FILTERED]"))
      expect(redact("DB_PASSWORD=Xk2mQ9pL", path: ".env.template")).to eq("DB_PASSWORD=[FILTERED]")
      [
        "SECRET_KEY: changeme",
        "API_TOKEN: xxx",
        "CLIENT_SECRET: <client-secret>",
        "PASSWORD: your_password_here",
        "SECRET_KEY_BASE: ",
        "SESSION_SECRET: secret"
      ].each { |line| expect(redact(line, path: "config/x.example.yml")).to eq(line) }
      expect(redact("API_KEY=your_api_key_here", path: ".env.example")).to eq("API_KEY=your_api_key_here")
    end

    it "filters a cipher key, whose name has no secret word but whose value is key material" do
      key = "#{("A".."Z").to_a.join}#{("a".."p").to_a.join}12="
      expect(redact("LEGACY_CBC_KEY: #{key}", path: "config/x.example.yml")).to eq("LEGACY_CBC_KEY: [FILTERED]")
      expect(redact(%(hmac_key = "#{key}"))).to eq(%(hmac_key = "[FILTERED]"))
      expect(RailsAiContext::Redaction.value("LEGACY_CBC_KEY_NEW", key)).to eq("[FILTERED]")
      expect(redact("GOOGLE_RECAPTCHA_SITE_KEY: 6Lc_fake_site_key_value_for_specs_0000", path: "config/x.example.yml"))
        .to eq("GOOGLE_RECAPTCHA_SITE_KEY: 6Lc_fake_site_key_value_for_specs_0000")
    end

    it "filters a literal assigned through ENV[], an instance variable, a constant or ||=" do
      {
        %(ENV["SECRET_KEY_BASE"] = "Xk2mQ9pLw7Rt5vB1") => %(ENV["SECRET_KEY_BASE"] = "[FILTERED]"),
        %(ENV['API_TOKEN'] ||= 'Xk2mQ9pLw7Rt') => %(ENV['API_TOKEN'] ||= '[FILTERED]'),
        %(@token ||= "Xk2mQ9pLw7Rt5vB") => %(@token ||= "[FILTERED]"),
        %(password ||= "hunter2x") => %(password ||= "[FILTERED]"),
        %(@api_key = "Xk2mQ9pLw7Rt") => %(@api_key = "[FILTERED]"),
        %(API_TOKEN = "Xk2mQ9pLw7Rt".freeze) => %(API_TOKEN = "[FILTERED]".freeze),
        %(secret &&= "Xk2mQ9pLw7Rt") => %(secret &&= "[FILTERED]"),
        %(token += "Xk2mQ9pLw7Rt") => %(token += "[FILTERED]")
      }.each { |line, want| expect(redact(line)).to eq(want) }
      expect(redact(%(params["token"] == "Xk2mQ9pLw7Rt"))).to eq(%(params["token"] == "Xk2mQ9pLw7Rt"))
    end

    it "reads a .yml.example, .yml.sample or .yml.template file as YAML" do
      hex = "3b" * 20
      %w[config/security.yml.example config/database.yml.sample config/x.yaml.template].each do |path|
        expect(redact("  encryption_key: #{hex}", path: path)).to eq("  encryption_key: [FILTERED]")
      end
      expect(redact("  password: changeme", path: "config/database.yml.example")).to eq("  password: changeme")
    end

    it "reads a .yml.erb file as YAML" do
      expect(redact("  password: s3cr3tP4ss", path: "config/database.yml.erb")).to eq("  password: [FILTERED]")
      expect(redact("  password: <%= ENV['DB_PASSWORD'] %>", path: "config/database.yml.erb"))
        .to eq("  password: <%= ENV['DB_PASSWORD'] %>")
    end

    it "filters base64 that starts with a slash and keeps a path" do
      expect(redact(%(api_key: "/aB3dE+fGh9iJkL0mN=="))).to eq(%(api_key: "[FILTERED]"))
      expect(redact(%(api_key: "/aB3dEfGh9iJkL0mN"))).to eq(%(api_key: "[FILTERED]"))
      expect(redact(%(secret_file: "/etc/app/secret.pem"))).to eq(%(secret_file: "/etc/app/secret.pem"))
    end

    # A `_KEY` name is as often a cache or i18n key as a credential, so the value's shape decides.
    it "filters a credential-looking value under a *_KEY name and keeps a plain key" do
      admin = "q7Wz9xKp" * 4
      {
        "ALGOLIA_ADMIN_KEY=#{admin}" => "ALGOLIA_ADMIN_KEY=[FILTERED]",
        %(MAPBOX_KEY = "pk#{admin}") => %(MAPBOX_KEY = "[FILTERED]"),
        %(apiKey: '#{admin}',) => %(apiKey: '[FILTERED]',),
        "  algolia_key: #{admin}" => "  algolia_key: [FILTERED]"
      }.each { |line, want| expect(redact(line, path: "config/x.yml")).to eq(want) }
      [
        "CACHE_KEY=posts_index", "I18N_KEY=users.title", %(cache_key: "views/posts/1"),
        %(key: "users.index.title"), %(foreign_key: "author_id"), %(MONKEY = "q7Wz9xKpq7Wz9xKpq7Wz"),
        %(key: "2024_01_15_add_users"), %(signing_key_header: "X-Signing-Key"),
        %("key": "wp-content/uploads/2024/01/screenshot2024abcdef123456.png")
      ].each { |line| expect(redact(line)).to eq(line) }
    end

    it "filters an Anthropic or OpenAI API key wherever it appears" do
      ant = "sk-ant-api03-#{'Ab3dEf9h' * 6}"
      oai = "sk-proj-#{'Zx8Yw7Vu' * 5}"
      expect(redact(%(data = build("key: #{ant}")))).to eq(%(data = build("[FILTERED]")))
      expect(redact(%(# export OPENAI=#{oai}))).to eq("# export OPENAI=[FILTERED]")
      expect(redact(%(<div class="sk-fading-circle sk-spinner">))).to eq(%(<div class="sk-fading-circle sk-spinner">))
    end

    it "keeps a URL query and a placeholder with `your` inside it" do
      [
        %(email_token += "?safe_mode=no_plugins,no_themes" if safe),
        %(agent.options['api_key'] = 'put-your-key-here'),
        %(token: "paste_your_token")
      ].each { |line| expect(redact(line)).to eq(line) }
    end

    it "filters a dash-joined password that reads like a header name" do
      expect(redact(%(password: "P4ss-W0rd"))).to eq(%(password: "[FILTERED]"))
      expect(redact(%(password: "Admin-Pass1"))).to eq(%(password: "[FILTERED]"))
      expect(redact(%(api_key_header: "X-Api-Key"))).to eq(%(api_key_header: "X-Api-Key"))
    end

    it "filters a secret literal passed through a call or block that names the secret" do
      v = "Xk2mQ9pLw7Rt5vB1"
      {
        %(ENV.fetch("SECRET_KEY_BASE", "#{v}")) => %(ENV.fetch("SECRET_KEY_BASE", "[FILTERED]")),
        %(ENV.fetch('API_TOKEN') { '#{v}' }) => %(ENV.fetch('API_TOKEN') { '[FILTERED]' }),
        %(let(:api_key) { "#{v}" }) => %(let(:api_key) { "[FILTERED]" }),
        %(stub_const("SECRET_TOKEN", "#{v}")) => %(stub_const("SECRET_TOKEN", "[FILTERED]")),
        %(option :client_secret, :string, default: "#{v}") => %(option :client_secret, :string, default: "[FILTERED]"),
        %(Rails.application.credentials.fetch(:stripe, "#{v}")) => %(Rails.application.credentials.fetch(:stripe, "[FILTERED]"))
      }.each { |line, want| expect(redact(line)).to eq(want) }
      [
        %(ENV.fetch("SECRET_KEY_BASE") { raise "missing" }),
        %(ENV.fetch("CACHE_KEY", "posts_index")),
        %(let(:api_key) { create(:api_key) }),
        %(ENV.fetch("API_TOKEN", nil)),
        %(let(:user) { "someone_longer" }),
        # A list of names is not a name and its value.
        %(expect(grants).to include("client_credentials", "authorization_code")),
        %(params.except('password', 'password_confirmation')),
        %(when "pass", "failed_attempt"),
        %(key, user = creds.values_at("api_key", "api_username"))
      ].each { |line| expect(redact(line)).to eq(line) }
      expect(redact(%(allow(Config).to receive(:signing_secret) { "#{v}" })))
        .to eq(%(allow(Config).to receive(:signing_secret) { "[FILTERED]" }))
    end

    it "reads a ternary's branches as values, not as a key and its value" do
      [
        %(grade = passed ? "pass" : "failed_attempt"),
        %(label = ok ? 'token' : 'Anonymous1'),
        %(x = admin ? password : "fallback_value"),
        %(re = /(?:\\salt="Xk2mQ9pLw7")/)
      ].each { |line| expect(redact(line)).to eq(line) }
      expect(redact(%({ "token": "Xk2mQ9pLw7Rt" }))).to eq(%({ "token": "[FILTERED]" }))
      expect(redact(%(opts = { pass: "Xk2mQ9pL" }))).to eq(%(opts = { pass: "[FILTERED]" }))
    end

    it "filters a letters-only or digits-only secret under a secret-named key" do
      expect(redact(%(password: "correcthorsebatterystaple"))).to eq(%(password: "[FILTERED]"))
      expect(redact(%(api_key = "SUPERSECRETKEYVALUE"))).to eq(%(api_key = "[FILTERED]"))
      expect(redact(%(pin_token: "83920174"))).to eq(%(pin_token: "[FILTERED]"))
      expect(redact("DB_PASSWORD: hunterhunter", path: "config/x.yml")).to eq("DB_PASSWORD: [FILTERED]")
    end

    it "keeps what a secret-named key holds that is clearly not a secret" do
      [
        %(api_key_header: "X-Api-Key"),
        %(API_KEY_HEADER = "Api-Key"),
        %(token_version: "2.4.1"),
        %(token_date: "2026-09-28"),
        %(password: 'password'),
        %(ACCESS_TOKEN_ENV = "USER_ACCESS_TOKEN"),
        %(api_key: "your-api-key"),
        %(api_token: "{api_token}"),
        # From an auth provider and a payments controller:
        # env, parameter and cache-key names built from a secret word.
        %(USER_TOKEN_KEY = "_DISCOURSE_USER_TOKEN"),
        %(API_KEY_ENV = "_DISCOURSE_API"),
        %(PARAMETER_USER_API_KEY = "user_api_key"),
        %(LINK_TOKEN_KEY = 'app-bank-link-token'),
        # Discourse's Zeitwerk inflections map a file name to its constant.
        %("csrf_token_verifier" => "CSRFTokenVerifier",),
        %(#   "access_token": "SOME-ACCESS-KEY",)
      ].each { |line| expect(redact(line)).to eq(line) }
      expect(redact("    password: Passwort", path: "config/locales/de.yml")).to eq("    password: Passwort")
    end

    it "still filters a secret that spells a secret word but carries digits" do
      expect(redact(%(api_key: "super_secret_2026"))).to eq(%(api_key: "[FILTERED]"))
    end

    it "filters JSON values with and without a space after the colon" do
      line = %({"x_refresh_token_expires_in":8726400,"refresh_token":"AB12cd34","access_token":"#{jwt}","token_type":"bearer"})

      redacted = redact(line)

      expect(redacted).to eq(%({"x_refresh_token_expires_in":8726400,"refresh_token":"[FILTERED]","access_token":"[FILTERED]","token_type":"bearer"}))
      expect(redact(%("client_secret": "abc123def"))).to eq(%("client_secret": "[FILTERED]"))
    end

    it "filters a whole PEM key held in one literal, body and all" do
      pem = "-----BEGIN PRIVATE KEY-----\\n#{'MIIEvQ' * 11}\\n-----END PRIVATE KEY-----\\n"
      redacted = redact(%(  "private_key": "#{pem}",))

      expect(redacted).to eq(%(  "private_key": "[FILTERED]",))
      expect(redacted).not_to include("MIIEvQ")
    end

    it "filters a whole key held in one literal when armor headers sit before the body" do
      body = "Zx8Yw7Vu" * 8
      enc = "-----BEGIN RSA PRIVATE KEY-----\\nProc-Type: 4,ENCRYPTED\\nDEK-Info: AES-128-CBC,#{'AB12' * 8}\\n\\n#{body}\\n-----END RSA PRIVATE KEY-----\\n"
      pgp = "-----BEGIN PGP PRIVATE KEY BLOCK-----\\nVersion: GnuPG v2\\n\\n#{body}\\n-----END PGP PRIVATE KEY BLOCK-----"
      expect(redact(%(content "#{enc}"))).to eq(%(content "[FILTERED]"))
      expect(redact(%(key = "#{pgp}"))).to eq(%(key = "[FILTERED]"))
      expect(redact(%(placeholder: "-----BEGIN PRIVATE KEY-----\\nMIIEvQ...\\n-----END PRIVATE KEY-----"))).to include("MIIEvQ...")
    end

    it "filters a literal shaped like a credential under any name" do
      expect(redact(%(STRIPE = "sk_live_#{'b' * 20}"))).to eq(%(STRIPE = "[FILTERED]"))
      expect(redact(%(HEADER = "#{jwt}"))).to eq(%(HEADER = "[FILTERED]"))
      expect(redact("aws_id: AKIA#{'A' * 16}")).to eq("aws_id: [FILTERED]")
    end

    it "filters an unquoted scalar under a secret-named key in YAML" do
      expect(redact("  jwt_hmac_secret: #{'a1' * 43}", path: "config/custom.yml"))
        .to eq("  jwt_hmac_secret: [FILTERED]")
      expect(redact("  password: <%= ENV['DB_PASSWORD'] %>", path: "config/database.yml"))
        .to eq("  password: <%= ENV['DB_PASSWORD'] %>")
    end

    # Code that passes or reads a token, which older rules rewrote.
    it "never rewrites code" do
      [
        "render_data(token: link_token(@order).result)",
        "api_key: KeySerializer.new(user).show(scope),",
        %(client_secret: ENV.fetch("OAUTH_CLIENT_SECRET"),),
        %(vendor_refresh_token: parsed_response_json["refresh_token"],),
        "token: '<%= link_token %>',",
        "Authorization: Bearer <service_access_token>",
        %(password: "\#{prefix}-suffix"),
        %(api_key: "<your-api-key>"),
        %(password: ""),
        %(password_length: "12"),
        %(render "app/views/orders/_order_card_component"),
        # A long random literal is an id as often as a key: file ids and record ids.
        %(TEMPLATE_FILE_ID = "#{random}"),
        %(TOKEN_USE = "report_download"),
        %("access_token": "YOUR_ACCESS_TOKEN"),
        "password: params[:password]",
        "def scheduled_publication; end",
        "  token: SomeService.call(user)"
      ].each { |line| expect(redact(line)).to eq(line) }
    end

    # Config where a secret-named key holds no secret.
    it "never rewrites a route, a message, a URL, a tiny value or an example" do
      expect(redact("post 'api/verify_token' => 'users#verify_token'")).to eq("post 'api/verify_token' => 'users#verify_token'")
      expect(redact("EXPIRING_TOKEN = '0'")).to eq("EXPIRING_TOKEN = '0'")
      # From Mastodon and Discourse: a fetch option, an enum, header names, a
      # locale string.
      expect(redact("  credentials: 'include',")).to eq("  credentials: 'include',")
      expect(redact("enum :method, { password: 'password', sign_in_token: 'sign_in_token' }"))
        .to eq("enum :method, { password: 'password', sign_in_token: 'sign_in_token' }")
      expect(redact(%(API_KEY_ENV = "HTTP_API_KEY"))).to eq(%(API_KEY_ENV = "HTTP_API_KEY"))
      expect(redact("    password: Mot de passe", path: "config/locales/fr.yml")).to eq("    password: Mot de passe")
      expect(redact("    password: Password", path: "config/locales/en.yml")).to eq("    password: Password")
      expect(redact("    password_and_2fa: 密碼kap雙因素驗證(2FA)", path: "config/locales/nan-TW.yml"))
        .to eq("    password_and_2fa: 密碼kap雙因素驗證(2FA)")
      expect(redact(%(  invalid_token: "The token you sent has expired"), path: "config/errors.yml"))
        .to eq(%(  invalid_token: "The token you sent has expired"))
      expect(redact("  reset_password: https://example.com/reset", path: "config/urls.yml"))
        .to eq("  reset_password: https://example.com/reset")
      expect(redact(%(forgot_password: "{frontend}/reset-password?token={token}"), path: "config/urls.yml"))
        .to eq(%(forgot_password: "{frontend}/reset-password?token={token}"))
      expect(redact(%(#   "access_token": "YOUR JWT TOKEN",))).to eq(%(#   "access_token": "YOUR JWT TOKEN",))
      expect(redact("JWT_HMAC_SECRET: replace_me_locally", path: "config/application.example.yml"))
        .to eq("JWT_HMAC_SECRET: replace_me_locally")
    end
  end

  # A PEM key written across lines is only a key between its markers, which a
  # single line cannot see.
  describe ".redact_source_lines" do
    it "filters each line of a PEM body and keeps the line count" do
      lines = [ "KEY = <<~PEM", "  -----BEGIN RSA PRIVATE KEY-----", "  #{'MIIEow' * 10}", "  #{'AbCd12' * 10}",
                "  -----END RSA PRIVATE KEY-----", "PEM", "token: build(user)" ]

      redacted = described_class.redact_source_lines(lines)

      expect(redacted.size).to eq(lines.size)
      expect(redacted[2]).to eq("  [FILTERED]")
      expect(redacted[3]).to eq("  [FILTERED]")
      expect(redacted.values_at(0, 1, 4, 5, 6)).to eq(lines.values_at(0, 1, 4, 5, 6))
    end

    it "reads a BEGIN marker that code names as code, and ends a block at its first non-body line" do
      lines = [
        %(  { name: "RSA Private Key", regex: /-----BEGIN RSA PRIVATE KEY-----/ },),
        %(  PATTERN = "-----BEGIN RSA PRIVATE KEY-----".freeze),
        %(  MARKER = "-----BEGIN RSA PRIVATE KEY-----"),
        "end",
        "",
        "  def scrub(data)",
        "    data.gsub(PATTERN, '')",
        "  end",
        %(  fake = "-----BEGIN RSA PRIVATE KEY-----),
        "  def after_an_unclosed_marker; end"
      ]

      expect(described_class.redact_source_lines(lines)).to eq(lines)
    end

    it "filters a key written as joined string lines" do
      lines = [ %(KEY = "-----BEGIN RSA PRIVATE KEY-----\\n" \\), %(  "#{'MIIEow' * 10}\\n" \\),
                %(  "#{'AbCd12' * 10}\\n" \\), %(  "-----END RSA PRIVATE KEY-----\\n"), "def after; end" ]

      redacted = described_class.redact_source_lines(lines)

      expect(redacted.values_at(1, 2)).to all(eq("  [FILTERED]"))
      expect(redacted.values_at(3, 4)).to eq(lines.values_at(3, 4))
    end

    it "filters a PGP private key block like a PEM key" do
      lines = [ "-----BEGIN PGP PRIVATE KEY BLOCK-----", "Version: GnuPG v2", "", "lQOYBF#{'aB3dE9' * 10}",
                "#{'Zx8Yw7' * 10}", "=Qm9x", "-----END PGP PRIVATE KEY BLOCK-----", "done" ]

      redacted = described_class.redact_source_lines(lines)

      expect(redacted.values_at(3, 4, 5)).to all(eq("[FILTERED]"))
      expect(redacted.values_at(0, 6, 7)).to eq(lines.values_at(0, 6, 7))
    end

    # A certificate is public: its body is not a key's.
    it "leaves a certificate body alone" do
      lines = [ "-----BEGIN CERTIFICATE-----", "MIIDdzCCAl+gAwIBAgIEAgAAuTANBgkqhkiG9w0BAQUFADBaMQswCQYDVQQGEwJJ", "-----END CERTIFICATE-----" ]

      expect(described_class.redact_source_lines(lines)).to eq(lines)
    end
  end

  describe ".redact_log_line" do
    it "filters a password confirmation in request parameters" do
      line = %(Parameters: {"password"=>"hunter2x", "password_confirmation"=>"hunter2x"})

      expect(described_class.redact_log_line(line))
        .to eq(%(Parameters: {"password"=>"[FILTERED]", "password_confirmation"=>"[FILTERED]"}))
    end

    it "filters a credential-looking *_KEY value in a log line and keeps a plain key" do
      admin = "q7Wz9xKp" * 4
      expect(described_class.redact_log_line("boot ALGOLIA_ADMIN_KEY=#{admin} CACHE_KEY=posts_index I18N_KEY=users.title"))
        .to eq("boot ALGOLIA_ADMIN_KEY=[FILTERED] CACHE_KEY=posts_index I18N_KEY=users.title")
      expect(described_class.redact_log_line(%(params {"mapbox_key"=>"#{admin}", "cache_key"=>"views/posts/1"})))
        .to eq(%(params {"mapbox_key"=>"[FILTERED]", "cache_key"=>"views/posts/1"}))
    end

    it "decides a log NAME=value once, whichever pattern reads it" do
      {
        "callback token_url=https://example.com/cb" => "callback token_url=https://example.com/cb",
        "TOKEN_USE=signin" => "TOKEN_USE=signin",
        "set user.token=Xk2mQ9pLw7Rt" => "set user.token=[FILTERED]",
        %(params {"token_url"=>"https://example.com/cb"}) => %(params {"token_url"=>"https://example.com/cb"})
      }.each { |line, want| expect(described_class.redact_log_line(line)).to eq(want) }
    end

    it "filters the password in a connection URL" do
      expect(described_class.redact_log_line("could not connect: postgres://app:Xk2mQ9pL@localhost/app"))
        .to eq("could not connect: postgres://[FILTERED]@localhost/app")
      expect(described_class.redact_log_line("Redis at redis://:Xk2mQ9pL@redis:6379/0 refused"))
        .to eq("Redis at redis://[FILTERED]@redis:6379/0 refused")
    end

    it "filters a PEM body on the lines after its marker" do
      lines = [ "-----BEGIN RSA PRIVATE KEY-----", "Zx8Yw7Vu" * 8, "Ab3dE9fG" * 8, "-----END RSA PRIVATE KEY-----", "Completed 200 OK" ]

      redacted = described_class.redact_log_lines(lines)

      expect(redacted.values_at(1, 2)).to all(eq("[FILTERED]"))
      expect(redacted.last).to eq("Completed 200 OK")
    end

    # One NAME=value rule for logs and source, so the two agree on which names hold a secret.
    it "reads NAME=value in a log line with the source rule" do
      {
        "boot DB_PASS=hunter22 PORT=3000" => "boot DB_PASS=[FILTERED] PORT=3000",
        "export GITHUB_TOKEN=Xk2mQ9pLw7Rt" => "export GITHUB_TOKEN=[FILTERED]",
        "MONKEY=banana private_mode=true TOKEN_TTL=3600" => "MONKEY=banana private_mode=true TOKEN_TTL=3600"
      }.each { |line, expected| expect(described_class.redact_log_line(line)).to eq(expected) }
    end

    # The value patterns ran to the next space, so a quoted value lost its
    # closing quote and the comma after it.
    it "keeps the quotes and what follows a filtered value" do
      {
        %(headers: {"Authorization: Bearer abc123def", "X": 1}) => %(headers: {"Authorization: [FILTERED]", "X": 1}),
        %(env "SECRET_KEY_BASE=abc123def" set) => %(env "SECRET_KEY_BASE=[FILTERED]" set),
        %(  "Cookie: _session=abc123def", next) => %(  "Cookie: [FILTERED]", next),
        %(run with STRIPE_API_KEY="abc123def" now) => %(run with STRIPE_API_KEY="[FILTERED]" now),
        %(cfg = "session_id=abc123def") => %(cfg = "session_id=[FILTERED]")
      }.each { |line, expected| expect(described_class.redact_log_line(line)).to eq(expected) }
    end
  end

  # The env tool printed a credentials default of `'{}'` as `[FILTERED]`; an empty value holds no secret.
  describe ".value" do
    it "prints an empty default under a secret name" do
      [ "'{}'", "{}", "[]", '""', "''", "nil", "false", "0" ].each do |empty|
        expect(described_class.value("WAREHOUSE_CREDENTIALS_JSON", empty)).to eq(empty)
      end
    end

    it "filters a credential-looking default under a *_KEY name and keeps a plain key" do
      expect(described_class.value("ALGOLIA_ADMIN_KEY", "q7Wz9xKp" * 4)).to eq("[FILTERED]")
      expect(described_class.value("CACHE_KEY", "posts_index")).to eq("posts_index")
      expect(described_class.value("I18N_KEY", "users.title")).to eq("users.title")
    end

    it "still filters a real default under a secret name" do
      expect(described_class.value("API_SECRET", "'a1b2c3d4'")).to eq("[FILTERED]")
    end
  end

  describe ".call" do
    it "strips URI userinfo" do
      expect(described_class.call("redis://app:hunter2@cache.internal:6379/0"))
        .to eq("redis://[FILTERED]@cache.internal:6379/0")
    end

    it "strips a quoted value behind a secret-ish key" do
      expect(described_class.call('password: "hunter2"')).to eq('password: "[FILTERED]"')
      expect(described_class.call('api_key => "abc123"')).to eq('api_key => "[FILTERED]"')
    end

    it "strips a bare assignment to a secret-ish name" do
      expect(described_class.call('secret_key = "s3cr3t"')).to eq('secret_key = "[FILTERED]"')
    end

    it "leaves a value that carries no credential alone" do
      expect(described_class.call("config.eager_load = true")).to eq("config.eager_load = true")
    end

    it "leaves a word that merely contains a key name alone" do
      expect(described_class.call("passwordless_login = true")).to eq("passwordless_login = true")
    end

    it "handles a nil value" do
      expect(described_class.call(nil)).to be_nil
    end
  end

  describe ".redact_and_shorten" do
    # The bug this exists to make unwritable: shortening first cuts the
    # credential away from the `@host` the pattern needs, so the prefix of a
    # real password ships in plaintext.
    it "redacts a credential that a cut would have separated from its host" do
      long = "redis://app:#{'z' * 200}@cache.internal:6379/0"

      expect(described_class.redact_and_shorten(long, 60)).to eq("redis://[FILTERED]@cache.internal:6379/0")
    end

    it "redacts a long quoted secret before the cut can split the quotes" do
      long = %(password: "#{'z' * 200}")

      expect(described_class.redact_and_shorten(long, 60)).to eq('password: "[FILTERED]"')
    end

    it "still shortens a long value that carries no credential" do
      result = described_class.redact_and_shorten("a" * 200, 60)

      expect(result.length).to eq(60)
      expect(result).to end_with("...")
    end

    it "leaves a short value untouched" do
      expect(described_class.redact_and_shorten("timeout = 30", 60)).to eq("timeout = 30")
    end
  end

  # The config listener sees the assigned value on its own; the setting's
  # name is the only thing that says whether it is a secret. These exercise
  # the value half of the one entry point.
  describe ".redact_assignment, on the value" do
    it "filters a value assigned to a secret-named setting" do
      expect(described_class.redact_assignment(:secret_key, value: '"s3cr3t"', source: nil)[:value]).to eq('"[FILTERED]"')
      expect(described_class.redact_assignment("api_key", value: '"abc123"', source: nil)[:value]).to eq('"[FILTERED]"')
    end

    it "keeps the quoting style it was given" do
      expect(described_class.redact_assignment(:password, value: "'hunter2'", source: nil)[:value]).to eq("'[FILTERED]'")
      expect(described_class.redact_assignment(:password, value: "ENV['PW']", source: nil)[:value]).to eq("[FILTERED]")
    end

    it "leaves an ordinary setting's value alone" do
      expect(described_class.redact_assignment(:eager_load, value: "true", source: nil)[:value]).to eq("true")
      expect(described_class.redact_assignment(:timeout_in, value: "30.minutes", source: nil)[:value]).to eq("30.minutes")
    end

    it "still scrubs a credential embedded in an ordinary setting's value" do
      expect(described_class.redact_assignment(:cache_store, value: '"redis://app:pw@cache:6379"', source: nil)[:value])
        .to eq('"redis://[FILTERED]@cache:6379"')
    end

    it "handles a setting with no value" do
      expect(described_class.redact_assignment(:jwt, value: nil, source: nil)[:value]).to be_nil
    end

    # An evaluated value is not always a String: the AST extractor returns
    # arrays, hashes, symbols and numbers. Letting those past because they
    # are not Strings leaves the credential in the one field that skipped
    # the check.
    # Element-wise, not wholesale: the reader still learns the shape - that
    # there are two keys, that a hash has a `token` - while the values go.
    it "filters a secret-named setting holding an array" do
      expect(described_class.redact_assignment(:secret_keys, value: [ "abc123", "def456" ], source: nil)[:value])
        .to eq([ "[FILTERED]", "[FILTERED]" ])
    end

    it "filters a secret-named setting holding a hash" do
      expect(described_class.redact_assignment(:credentials, value: { token: "tok_live_xyz" }, source: nil)[:value])
        .to eq(token: "[FILTERED]")
    end

    it "leaves a non-string value of an ordinary setting alone" do
      expect(described_class.redact_assignment(:timeout_in, value: 30, source: nil)[:value]).to eq(30)
      expect(described_class.redact_assignment(:eager_load, value: true, source: nil)[:value]).to be(true)
      expect(described_class.redact_assignment(:queue_adapter, value: :sidekiq, source: nil)[:value]).to eq(:sidekiq)
    end

    # A descriptor still describes, whatever type it holds.
    it "leaves a descriptor's non-string value alone" do
      expect(described_class.redact_assignment(:password_length, value: 6..128, source: nil)[:value]).to eq(6..128)
    end

    # A Symbol is an identifier, a boolean is a policy, a number is a size.
    # None of them is credential material, and filtering them hides the
    # config a reader came for.
    it "keeps a secret-named setting's symbol and boolean values" do
      expect(described_class.redact_assignment(:reset_password_keys, value: [ :email ], source: nil)[:value]).to eq([ :email ])
      expect(described_class.redact_assignment(:send_password_change_notification, value: false, source: nil)[:value]).to be(false)
      expect(described_class.redact_assignment(:api_key, value: :from_env, source: nil)[:value]).to eq(:from_env)
    end

    it "filters the strings inside a secret-named collection" do
      expect(described_class.redact_assignment(:secret_keys, value: [ "abc123", "def456" ], source: nil)[:value])
        .to eq([ "[FILTERED]", "[FILTERED]" ])
    end

    # The classic stock Rails line: the setting is not secret-named, the key
    # inside it is.
    it "filters a credential nested under an ordinary setting" do
      settings = { user_name: "app", password: "hunter2", address: "smtp.example.com" }

      expect(described_class.redact_assignment(:smtp_settings, value: settings, source: nil)[:value])
        .to eq(user_name: "app", password: "[FILTERED]", address: "smtp.example.com")
    end

    it "filters a credential nested two levels down" do
      value = { cache: { url: "redis://u:pw@host:6379", token: "tok_live_xyz" } }

      expect(described_class.redact_assignment(:stores, value: value, source: nil)[:value])
        .to eq(cache: { url: "redis://[FILTERED]@host:6379", token: "[FILTERED]" })
    end

    it "still scrubs a URI credential inside an ordinary collection" do
      expect(described_class.redact_assignment(:cache_store, value: [ :redis_cache_store, { url: "redis://u:pw@h:6379" } ], source: nil)[:value])
        .to eq([ :redis_cache_store, { url: "redis://[FILTERED]@h:6379" } ])
    end
  end

  # Devise's pepper and ActiveRecord encryption's keys are the two most
  # common hand-written secrets in config/initializers.
  describe "secret vocabulary" do
    it "recognises the names people actually put credentials under" do
      %i[pepper salt master_key signing_key encryption_key deterministic_key key_derivation_salt].each do |name|
        expect(described_class.redact_assignment(name, value: '"abc123deadbeef"', source: nil)[:value])
          .to eq('"[FILTERED]"'), "#{name} was not treated as a secret"
      end
    end

    # Names arrive uppercase from a process environment and lowercase from a
    # config path. One word list answers both.
    it "recognises a name in any case" do
      expect(described_class.secret_name?("API_KEY")).to be(true)
      expect(described_class.call(%(API_KEY = "abc123"))).to eq(%(API_KEY = "[FILTERED]"))
      expect(described_class.redact_assignment("API_KEY", value: '"abc123"', source: nil)[:value])
        .to eq('"[FILTERED]"')
    end

    # `primary_key` is ordinary ActiveRecord vocabulary; only the encryption
    # one is a credential, and the path is what tells them apart.
    it "leaves a bare primary_key alone but filters the encryption one" do
      expect(described_class.redact_assignment(:primary_key, value: ":id", source: nil)[:value]).to eq(":id")
      expect(described_class.redact_assignment(%i[active_record encryption primary_key], value: '"deadbeef"', source: nil)[:value])
        .to eq('"[FILTERED]"')
    end
  end

  # The listener emits an evaluated value and the raw source slice for the
  # same assignment. Deciding separately let them disagree: `source` is
  # always a String, so a rule about the value's type never reached it, and
  # `secret_key = 12345` came out filtered in one field and plain in the
  # other. One decision, both fields.
  describe ".redact_assignment" do
    def redact(name, value, source)
      described_class.redact_assignment(name, value: value, source: source)
    end

    it "filters both fields for a numeric secret" do
      expect(redact(:secret_key, 12345, "12345"))
        .to eq(value: "[FILTERED]", source: "[FILTERED]")
    end

    it "keeps both fields for a policy switch" do
      expect(redact(:send_password_change_notification, false, "false"))
        .to eq(value: false, source: "false")
    end

    it "keeps both fields for a list of field names" do
      expect(redact(:reset_password_keys, [ :email ], "[:email]"))
        .to eq(value: [ :email ], source: "[:email]")
    end

    it "keeps both fields for a descriptor" do
      expect(redact(:password_length, "[INFERRED]", "6..128"))
        .to eq(value: "[INFERRED]", source: "6..128")
    end

    # A descriptor suffix suppresses a name, and that suppression used to win
    # even when the value was plainly a credential.
    it "filters a credential-shaped value a descriptor suffix would have excused" do
      expect(redact(:api_key_params, "sk_live_abcdefghijkl", '"sk_live_abcdefghijkl"'))
        .to eq(value: "[FILTERED]", source: '"[FILTERED]"')
    end

    it "still reaches a credential nested under an ordinary setting" do
      result = redact(:smtp_settings,
                      { user_name: "app", password: "hunter2" },
                      '{ user_name: "app", password: "hunter2" }')

      expect(result[:value]).to eq(user_name: "app", password: "[FILTERED]")
      expect(result[:source]).to include("[FILTERED]")
      expect(result[:source]).to include("app")
    end

    it "handles an assignment with no value" do
      expect(redact(:jwt, nil, nil)).to eq(value: nil, source: nil)
    end
  end

  # The env tool cannot redact a `.env.example` default the way a log line is
  # scrubbed - there is no surrounding key to match on, only the value. What
  # it needs from the module is the judgement, not the marker.
  # A `.env.example` exists to be read: its values are placeholders, and the
  # word "secret" in one is a label, not a credential. Only a value actually
  # shaped like a credential is worth hiding there.
  describe ".credential_shaped?" do
    it "recognises a hex blob or a vendor prefix" do
      expect(described_class.credential_shaped?("a1b2c3d4e5f60718")).to be(true)
      expect(described_class.credential_shaped?("sk_live_abc")).to be(true)
    end

    it "leaves a value that merely says 'secret' alone" do
      expect(described_class.credential_shaped?("<your-secret-here>")).to be(false)
      expect(described_class.credential_shaped?("generate_with_rails_secret")).to be(false)
      expect(described_class.credential_shaped?("some_key_name")).to be(false)
    end
  end

  describe ".redact_log_line" do
    it "uses the email marker for addresses" do
      expect(described_class.redact_log_line("Sent to ada@example.com"))
        .to eq("Sent to [EMAIL]")
    end

    it "uses the filtered marker for everything else" do
      expect(described_class.redact_log_line('{"password":"hunter2"}'))
        .to include("[FILTERED]")
    end

    # Every secret-ish name the module knows, in each of the four shapes a
    # Rails log writes. The list used to name four of them in two shapes, so
    # a `Parameters:` line shipped every credential but the password.
    %w[password passwd secret token api_key apikey access_key private_key
       credentials pepper salt master_key signing_key encryption_key
       access_token refresh_token auth_token otp_secret client_secret
       csrf_token session_token].each do |name|
      it "filters #{name} in every shape a log line writes" do
        expect(described_class.redact_log_line(%(#{name}=SHHH))).to eq("#{name}=[FILTERED]")
        expect(described_class.redact_log_line(%(#{name}: SHHH))).to eq("#{name}: [FILTERED]")
        expect(described_class.redact_log_line(%("#{name}"=>"SHHH"))).to eq(%("#{name}"=>"[FILTERED]"))
        expect(described_class.redact_log_line(%("#{name}":"SHHH"))).to eq(%("#{name}":"[FILTERED]"))
      end
    end

    it "filters every pair of a Rails Parameters line" do
      line = '  Parameters: {"token"=>"AAA1", "api_key"=>"AAA2", "secret"=>"AAA3", ' \
             '"access_token"=>"AAA4", "auth_token"=>"AAA5", "password"=>"AAA6", "otp_secret"=>"AAA7"}'

      redacted = described_class.redact_log_line(line)

      (1..7).each { |n| expect(redacted).not_to include("AAA#{n}") }
      expect(redacted.scan("[FILTERED]").size).to eq(7)
    end

    it "filters a bare Authorization header" do
      expect(described_class.redact_log_line("Authorization: Bearer abc.def"))
        .to eq("Authorization: [FILTERED]")
    end

    # Filtering these would hide the config the reader came for, and prose
    # is not an assignment however often it says "token".
    it "leaves policy values, prose and paths that merely name a secret" do
      [
        "password_length: 8 and token_expiry=3600",
        'Started GET "/admin/secret/list" for 127.0.0.1',
        "Refreshing the access token for user 5 now",
        "the passwordless_login flag is on",
        "Completed 200 OK in 5ms"
      ].each { |line| expect(described_class.redact_log_line(line)).to eq(line) }
    end

    it "never emits the old markers" do
      samples = [
        '{"password":"hunter2"}',
        "SECRET_KEY_BASE=abcdef0123456789",
        "[dotenv] Set SECRET_KEY_BASE, DATABASE_URL"
      ]

      samples.each do |sample|
        expect(described_class.redact_log_line(sample)).not_to include("REDACTED")
      end
    end
  end

  describe "the marker vocabulary" do
    it "publishes exactly the two markers" do
      expect(described_class::FILTERED).to eq("[FILTERED]")
      expect(described_class::EMAIL).to eq("[EMAIL]")
    end
  end

  describe ".value" do
    it "keeps a short plain default" do
      expect(described_class.value("PORT", "3000")).to eq("3000")
    end

    it "strips the quotes a literal arrived with" do
      expect(described_class.value("HOST", '"localhost"')).to eq("localhost")
    end

    it "filters a value in a credential format whatever its name" do
      expect(described_class.value("NPM_TOKEN", "npm_abcdefghijklmnopqrstuvwxyz0123456789")).to eq("[FILTERED]")
      expect(described_class.value("X", "sk_live_#{'b' * 20}")).to eq("[FILTERED]")
    end

    # The env tool filtered a 41-character contact address by length alone; a default is judged
    # by the rule source uses: its name, then its shape.
    it "keeps an address, a URL, a hostname or a word that is not a secret, however long" do
      {
        "CONTACT_EMAIL" => "customer-support-team@mail.example-company.com",
        "CALLBACK_URL" => "https://example.com/oauth/callback/with/a/long/path",
        "MAIL_HOST" => "smtp.mailer.example-company.com",
        "WELCOME_TEXT" => "a" * 41,
        "FILE_ID" => "0123456789abcdef0123456789abcdef",
        "SUPPORT_DESK_NAME" => "helpdesk_team"
      }.each { |name, default| expect(described_class.value(name, default)).to eq(default) }
      expect(described_class.value("SECRET_OWNER_EMAIL", "ops@example.com")).to eq("ops@example.com")
      expect(described_class.value("SMTP_PASSWORD", "ops@example.com")).to eq("[FILTERED]")
      expect(described_class.value("DATABASE_URL", "postgres://app:Xk2mQ9pL@db/app")).to eq("postgres://[FILTERED]@db/app")
    end

    it "filters a value under a secret name even when the value looks plain" do
      expect(described_class.value("SECRET_KEY_BASE", "changeme")).to eq("[FILTERED]")
    end

    it "keeps an example-file placeholder when the caller says placeholders are fine" do
      expect(described_class.value("API_KEY", "your_api_key_here", placeholder_ok: true)).to eq("your_api_key_here")
      expect(described_class.value("API_KEY", "Xk2mQ9pLw7Rt")).to eq("[FILTERED]")
    end

    # An example file's values exist to be read, and its names are secret-ish
    # by convention. Only a real credential shape is worth hiding there.
    it "judges an example-file value by its shape alone" do
      expect(described_class.value("DATABASE_PASSWORD", "postgres", placeholder_ok: true)).to eq("postgres")
      expect(described_class.value("API_KEY", "sk_live_abcdef0123456789", placeholder_ok: true)).to eq("[FILTERED]")
      expect(described_class.value("DATABASE_PASSWORD", "postgres")).to eq("[FILTERED]")
    end

    it "filters a credential-shaped example value that reads like a placeholder" do
      expect(described_class.value("STRIPE_KEY", "todo#{'a1' * 25}", placeholder_ok: true)).to eq("[FILTERED]")
      expect(described_class.value("KEY", "sk_live_changeme12", placeholder_ok: true)).to eq("[FILTERED]")
    end

    it "answers nil for nil" do
      expect(described_class.value("X", nil)).to be_nil
    end
  end

  describe ".redact_log_lines" do
    let(:lines) { [ "INFO started", "INFO Bearer sk_live_abcdef0123456789abcdef used", "INFO done" ] }

    it "redacts every line" do
      expect(described_class.redact_log_lines(lines)[1]).to eq("INFO Bearer [FILTERED] used")
    end

    # The search runs after redaction, so a term can only match text a
    # reader would see. Matching the hidden text first told a caller
    # whether a secret was in the log by whether a line came back.
    it "filters on the redacted text, never the original" do
      expect(described_class.redact_log_lines(lines, search: "sk_live_abc")).to eq([])
      expect(described_class.redact_log_lines(lines, search: "FILTERED")).to eq([ "INFO Bearer [FILTERED] used" ])
    end

    # The leak this pins: a targeted search for the value used to return the
    # line with the value still in it, because the patterns never caught it.
    it "returns a line searched for by its secret value with the value gone" do
      line = '  Parameters: {"token"=>"AAA1", "api_key"=>"AAA2"}'

      expect(described_class.redact_log_lines([ line ], search: "AAA1")).to eq([])
      expect(described_class.redact_log_lines([ line ]).first).not_to include("AAA1")
    end

    it "matches case-insensitively and ignores a blank search" do
      expect(described_class.redact_log_lines(lines, search: "STARTED")).to eq([ "INFO started" ])
      expect(described_class.redact_log_lines(lines, search: "  ")).to eq(described_class.redact_log_lines(lines))
    end
  end
end

RSpec.describe "Redaction marker vocabulary in lib" do
  it "spells no marker other than [FILTERED] and [EMAIL]" do
    lib_root = File.expand_path("../../../lib", __dir__)

    offenders = Dir.glob(File.join(lib_root, "**", "*.rb")).flat_map { |file|
      File.readlines(file).each_with_index.filter_map { |line, i|
        next unless line.match?(/\[REDACTED\]|\[redacted\]|REDACTED\]/)
        "#{file.sub("#{lib_root}/", '')}:#{i + 1}"
      }
    }

    expect(offenders).to be_empty,
      "Files still emitting a retired redaction marker: #{offenders.join(', ')}"
  end
end
