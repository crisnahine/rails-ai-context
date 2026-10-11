# frozen_string_literal: true

require_relative "e2e_helper"

# `doctor` on real installs: clean on the ones the install just made, and on
# an app with trouble, a failed row naming it - without writing to the app's
# database while it looks.
RSpec.describe "E2E: doctor", type: :e2e do
  describe "on a fresh install" do
    # --strict exits 1 on any failed check, which is how CI gates on it. A
    # warning (no test suite under --skip-test, no listen) passes.
    { "in-Gemfile" => :in_gemfile, "standalone" => :standalone }.each do |label, install_path|
      it "passes every check of the #{label} install, strict" do
        result = E2E::CliRunner.new(E2E.shared_app(install_path: install_path)).cli("doctor", "--strict")

        expect(result.success?).to be(true), result.to_s
        expect(result.stdout).not_to include("[FAIL]")
        expect(result.stdout).to include("MCP configs: 5 of 5 MCP configs valid")
        expect(result.stdout).to match(/Context files: .* up to date/)
      end
    end
  end

  # A copy of the shared in-Gemfile app, since these examples break it; each
  # puts back what it changed.
  describe "on an app with trouble" do
    before(:all) do
      source = E2E.shared_app(install_path: :in_gemfile)
      @app = source.copy_to(parent_dir: File.join(E2E.root, "doctor"), name: "blog")
      @cli = E2E::CliRunner.new(@app)
    end

    def app_file(relative) = File.join(@app.app_path, relative)

    # Claude Code reads .mcp.json as plain JSON, so a hand-edited one with a
    # trailing comma starts no server, while the install called it
    # "(unchanged)" and doctor passed it.
    it "fails the MCP configs row for a .mcp.json with a trailing comma, which init leaves as Claude Code cannot read it" do
      path = app_file(".mcp.json")
      original = File.read(path)
      # The comma after the entry's last member, the edit a person makes when
      # they delete a line below it.
      trailing = original.sub(/\]\n(\s*)\}/) { "],\n#{Regexp.last_match(1)}}" }
      expect(trailing).not_to eq(original)
      File.write(path, trailing)

      doctor = @cli.cli("doctor", "--strict")
      expect(doctor.success?).to be(false), doctor.to_s
      expect(doctor.stdout).to match(/\[FAIL\] MCP configs: .*\.mcp\.json \(Claude Code\): Claude Code cannot read it: it holds a trailing comma/)

      init = @cli.cli("init", stdin_input: "a\n1\n")
      expect(init.success?).to be(true), init.to_s
      expect(init.output).to include("Claude Code cannot read it: it holds a trailing comma")
      expect(init.output).to include("so it is left as it is")
      expect(File.read(path)).to eq(trailing)
    ensure
      File.write(path, original) if original
    end

    # Connecting to SQLite creates the file, which db:prepare then migrated
    # from nothing instead of loading the schema and seeds.
    it "reports a SQLite database that is not there as missing, and does not create it" do
      # Rails 7.0 keeps it under db/, later versions under storage/.
      database = %w[storage/test.sqlite3 db/test.sqlite3].map { |relative| app_file(relative) }.find { |file| File.exist?(file) }
      expect(database).not_to be_nil, "no test database in #{@app.app_path}"
      relative = database.delete_prefix("#{@app.app_path}/")
      moved = "#{database}.e2e-moved"
      File.rename(database, moved)

      result = @cli.cli("doctor")

      expect(File.exist?(database)).to be(false), "doctor created #{relative}\n#{result}"
      expect(result.stdout).to include("[FAIL] Database: the test database #{relative} does not exist")
      expect(result.stdout).to include("RAILS_ENV=test bin/rails db:prepare")
    ensure
      File.rename(moved, database) if moved && File.exist?(moved)
    end
  end
end
