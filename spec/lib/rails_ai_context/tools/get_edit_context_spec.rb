# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetEditContext do
  # A locale file gets only credential formats filtered, so the rules come from the file's name on
  # disk, which SafePath resolves; a case-insensitive disk opens it under the caller's spelling too.
  describe "a path typed in another spelling" do
    it "redacts the file by the name SafePath resolves it to" do
      Dir.mktmpdir do |root|
        real = File.join(root, "config", "Locales", "app.yml")
        FileUtils.mkdir_p(File.dirname(real))
        File.write(real, "production:\n  password: hunter2hunter2\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
        allow(RailsAiContext::SafePath).to receive(:locate).with("config/locales/app.yml", under: root)
          .and_return(RailsAiContext::SafePath::Resolution.new(realpath: real, relative: "config/Locales/app.yml", refusal: nil))

        text = described_class.call(file: "config/locales/app.yml", line: 2).content.first[:text]

        expect(text).to include("password: [FILTERED]")
      end
    end
  end

  # Defence in depth: a secrets file nobody listed is still a file this tool
  # will read, so the text it returns carries no credential-shaped value.
  describe "a secret in a file no pattern names" do
    it "filters the value and keeps the line" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config", "custom_secrets.yml"),
                   "production:\n  jwt_hmac_secret: #{'a1' * 43}\n  pool: 5\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "config/custom_secrets.yml", near: "jwt_hmac_secret")
                              .content.first[:text]

        expect(text).to include("jwt_hmac_secret")
        expect(text).to include("[FILTERED]")
        expect(text).not_to include("a1a1")
        expect(text).to include("pool: 5")
      end
    end

    # A header name is written with dashes, which hid the secret word in it.
    it "filters the value under a header name that spells a secret's" do
      v = "Xk2mQ9pLw7Rt#{'Z4ab'}"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/services"))
        File.write(File.join(root, "app/services/billing_client.rb"), <<~RUBY)
          class BillingClient
            def headers
              { "X-Api-Key" => "#{v}", "Content-Type" => "application/json" }
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/services/billing_client.rb", near: "headers").content.first[:text]

        expect(text).to include(%({ "X-Api-Key" => "[FILTERED]", "Content-Type" => "application/json" }))
        expect(text).not_to include(v)
      end
    end

    # The label above the window quoted the method's line as written, and an
    # endless method's line is its whole body.
    it "names an endless method's scope without its body" do
      v = "Xk2mQ9pLw7Rt#{'Z4ab'}"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/services"))
        File.write(File.join(root, "app/services/zz_service.rb"),
                   %(class ZzService\n  def headers = { "Authorization" => "Bearer #{v}" }\n  def call = headers\nend\n))
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/services/zz_service.rb", near: "headers").content.first[:text]

        expect(text).to include("**Context:** `class ZzService > def headers`")
        expect(text).to include(%(def headers = { "Authorization" => "Bearer [FILTERED]" }))
        expect(text).not_to include(v)
      end
    end

    # `near` was looked for in the file as written, so a guess at a secret's
    # start brought back a window and a wrong guess "not found".
    it "looks for near in the lines the caller is shown, so a guess at a filtered value finds nothing" do
      v = "Xk2mQ9pLw7Rt#{'Z4ab'}"
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config/initializers"))
        File.write(File.join(root, "config/initializers/billing.rb"), %(BILLING_API_TOKEN = "#{v}"\n))
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        right = described_class.call(file: "config/initializers/billing.rb", near: v[0, 6]).content.first[:text]
        wrong = described_class.call(file: "config/initializers/billing.rb", near: "Qq9zZz").content.first[:text]
        named = described_class.call(file: "config/initializers/billing.rb", near: "BILLING_API_TOKEN").content.first[:text]

        expect(right).to eq(wrong.sub("Qq9zZz", v[0, 6]))
        expect(right).to include("not found")
        expect(named).to include(%(BILLING_API_TOKEN = "[FILTERED]"))
      end
    end
  end
  before { described_class.reset_cache! }

  it "takes the method holding a match in a Ruby file that does not end in .rb" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib/tasks"))
      File.write(File.join(root, "lib/tasks/posts.rake"), "namespace :posts do\n  def stale\n    Post.where(stale: true)\n  end\nend\n")
      allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

      text = described_class.call(file: "lib/tasks/posts.rake", near: "Post.where", context_lines: 0).content.first[:text]

      expect(text).to include("(lines 2-4 of 5)").and include("**Context:** `def stale`")
    end
  end

  # A link that resolves nowhere was offered back as the file to try.
  describe "a file that is a link to nothing" do
    it "is not found, and suggests only files the tool can read" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models/archive"))
        File.symlink("missing.rb", File.join(root, "app/models/ghost.rb"))
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/models/ghost.rb", near: "x").content.first[:text]
        expect(text).to eq("File not found: app/models/ghost.rb. No file named ghost.rb is under app/.")

        File.write(File.join(root, "app/models/archive/ghost.rb"), "class Archive::Ghost; end\n")
        text = described_class.call(file: "app/models/ghost.rb", near: "x").content.first[:text]
        expect(text).to include("Did you mean: app/models/archive/ghost.rb?")
        expect(text).not_to include("Did you mean: app/models/ghost.rb")
      end
    end
  end

  describe ".call" do
    it "returns context around a matching method" do
      result = described_class.call(file: "app/models/user.rb", near: "has_many")
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text).to include("app/models/user.rb")
      expect(text).to include("has_many")
    end

    it "shows line numbers in the output" do
      result = described_class.call(file: "app/models/user.rb", near: "validates")
      text = result.content.first[:text]
      # Line numbers are right-justified, e.g. "   7  validates :email..."
      expect(text).to match(/\d+\s+validates/)
    end

    it "expands to full method when near matches a def" do
      result = described_class.call(file: "app/controllers/posts_controller.rb", near: "def create")
      text = result.content.first[:text]
      expect(text).to include("def create")
      expect(text).to include("post_params")
    end

    it "returns error when file is not found" do
      result = described_class.call(file: "app/models/nonexistent.rb", near: "anything")
      text = result.content.first[:text]
      expect(text).to include("File not found")
    end

    # The example path was built from the caller's own name, so it handed
    # `app/models/nonexistent.rb` back as the file to try.
    it "does not offer the missing path back as a suggestion" do
      text = described_class.call(file: "app/models/nonexistent.rb", near: "anything").content.first[:text]

      expect(text).to eq("File not found: app/models/nonexistent.rb. No file named nonexistent.rb is under app/.")
    end

    it "returns error when near pattern is not found in file" do
      result = described_class.call(file: "app/models/user.rb", near: "zzz_nonexistent_method")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available methods")
    end

    it "blocks access to sensitive files" do
      result = described_class.call(file: ".env", near: "SECRET")
      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to eq("Path not allowed: .env (sensitive file)")
    end

    it "prevents path traversal" do
      result = described_class.call(file: "../../etc/passwd", near: "root")
      text = result.content.first[:text]
      expect(text).to match(/not (found|allowed)/)
    end

    # A refusal is not "ran and found nothing", so a composer must not drop
    # it the way it drops an empty answer.
    it "marks a refused path as an answer, not an empty result" do
      refused = described_class.call(file: "../../etc/passwd", near: "root")

      expect(described_class.send(:empty?, refused)).to be false
    end

    it "requires the file parameter" do
      result = described_class.call(file: "", near: "test")
      text = result.content.first[:text]
      expect(text).to include("file")
      expect(text).to include("required")
    end

    it "requires the near parameter" do
      result = described_class.call(file: "app/models/user.rb", near: "")
      text = result.content.first[:text]
      expect(text).to include("near")
      expect(text).to include("required")
    end

    it "shows the code around a line it is given, whatever near would match first" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "app/models/gadget.rb"), "class Gadget\n  # name\n#{"  x = 1\n" * 20}  def label = name\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/models/gadget.rb", near: "name", line: 23).content.first[:text]

        expect(text).to include("  23    def label = name")
        expect(text).not_to include("# name")
      end
    end

    it "keeps the window on a line deep in a long method, naming the method" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "app/models/gadget.rb"), "class Gadget\n  def export\n#{"    x = 1\n" * 300}  end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/models/gadget.rb", line: 200, context_lines: 2).content.first[:text]

        expect(text).to include("(lines 198-202 of 304)").and include("**Context:** `class Gadget > def export`")
      end
    end

    # Prism gives ranked 2..4, a 29..29 and b 31..33; line 27 sits in no method.
    describe "a match below a method that already ended" do
      let(:source) do
        [ "class Post < ApplicationRecord", "  def self.ranked", "    order(:rank)", "  end", "",
          *(1..20).map { |i| "  scope :s#{i}, -> { where(n: #{i}) }" },
          "", "  validates :title, presence: true", "", "  def a = 1", "", "  def b", "    2", "  end", "end" ].join("\n") + "\n"
      end

      around do |example|
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.join(root, "app/models"))
          File.write(File.join(root, "app/models/post.rb"), source)
          @root = root
          example.run
        end
      end

      before { allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root)) }

      def text_for(**args)
        described_class.call(file: "app/models/post.rb", **args).content.first[:text]
      end

      it "keeps the context window and names only the class" do
        text = text_for(near: "validates :title")

        expect(text).to include("(lines 22-32 of 34)")
        expect(text).to include("**Context:** `class Post`\n")
      end

      it "shows an endless method as the one line it is" do
        text = text_for(near: "def a")

        expect(text).to include("**Context:** `class Post > def a`")
        expect(text).not_to include("def b")
      end

      it "names only the class for a line between methods" do
        expect(text_for(line: 27, context_lines: 1)).to include("(lines 26-28 of 34)").and include("**Context:** `class Post`\n")
      end
    end

    it "names the class a method belongs to, past a class << self and a one-line nested class" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/services"))
        File.write(File.join(root, "app/services/import_rows.rb"), <<~RUBY)
          class ImportRows
            class InvalidRow < StandardError; end

            class << self
              def build(rows)
                new(rows)
              end
            end

            def call
              rows.each(&:save!)
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        label = ->(near) { described_class.call(file: "app/services/import_rows.rb", near: near).content.first[:text][/\*\*Context:\*\* `[^`]*`/] }

        expect(label.call("def build")).to eq("**Context:** `class ImportRows > def build`")
        expect(label.call("def call")).to eq("**Context:** `class ImportRows > def call`")
      end
    end

    it "lists no def line from inside a heredoc among the available methods" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "app/models/doc.rb"), <<~RUBY)
          class Doc
            TEMPLATE = <<~CODE
              def fake
              end
            CODE

            def real
            end
          end
        RUBY
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/models/doc.rb", near: "zzz_missing").content.first[:text]

        expect(text).to end_with("Available methods:\n- `real` (line 7)")
      end
    end

    it "says a line past the end of the file is not in it when no near was given" do
      text = described_class.call(file: "app/models/user.rb", line: 9999).content.first[:text]

      expect(text).to include("Line 9999 is not in app/models/user.rb")
    end

    it "respects custom context_lines parameter" do
      result = described_class.call(file: "app/models/user.rb", near: "scope :active", context_lines: 1)
      text = result.content.first[:text]
      expect(text).to include("scope")
      # With context_lines: 1, output should be relatively short
      code_lines = text.scan(/^\s*\d+\s+/).size
      expect(code_lines).to be <= 10
    end
  end
end
