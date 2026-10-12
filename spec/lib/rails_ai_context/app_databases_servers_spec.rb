# frozen_string_literal: true

require "spec_helper"
require "socket"
require "uri"

# A lease on a real MySQL or MariaDB server that stops answering. Each group runs only when its URL
# is set, with the driver from gemfiles/database_servers.gemfile (see CONTRIBUTING.md).
RSpec.describe RailsAiContext::AppDatabases::Database do
  def self.server(env)
    ENV[env] ? false : "set #{env} to run this lease against a real database server"
  end

  # Passes bytes both ways until @silent, then holds the connection open and passes nothing back.
  def proxy_to(host, port)
    listener = TCPServer.new("127.0.0.1", 0)
    @sockets = [ listener ]
    @threads = [ Thread.new do
      loop do
        client = listener.accept
        server = TCPSocket.new(host, port)
        @sockets.push(client, server)
        @threads << Thread.new { IO.copy_stream(client, server) }
        @threads << Thread.new { loop { server.readpartial(65_536).then { |bytes| client.write(bytes) unless @silent } } }
      end
    end ]
    @threads.each { |thread| thread.report_on_exception = false }
    listener.addr[1]
  end

  def leased_through_proxy(env, extra = {})
    url = URI.parse(ENV.fetch(env))
    settings = { adapter: url.scheme, host: "127.0.0.1", port: proxy_to(url.host, url.port || 3306), username: url.user,
                 password: url.password, database: url.path.delete_prefix("/") }.merge(extra)
    silent = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "silent", settings)
    RailsAiContext::AppDatabases.build(
      environments: { Rails.env => { "primary" => ActiveRecord::Base.connection_db_config, "silent" => silent } },
      current: Rails.env, root: Dir.tmpdir, dumps: []
    ).fetch("silent")
  end

  # [the error the read ended with, seconds it took]; nil when it was still waiting after `limit` seconds.
  def read_after_silence(database, limit:)
    reading = Thread.new do
      database.with_connection do |conn|
        expect(conn.select_value("SELECT 1").to_i).to eq(1)
        @silent = true
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          conn.select_value("SELECT 2")
        rescue ActiveRecord::ActiveRecordError => e
          [ e, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
        end
      end
    end
    reading.report_on_exception = false
    reading.join(limit)&.value
  ensure
    reading&.kill
  end

  around do |example|
    RailsAiContext.configuration.query_timeout = 1
    example.run
  ensure
    RailsAiContext.configuration.query_timeout = 5
    @threads&.each(&:kill)
    @sockets&.each { |socket| socket.close unless socket.closed? }
  end

  shared_examples "a lease no silent server holds" do |env|
    # Twice query_timeout and a margin of five seconds: seven here.
    it "ends a read on a server that stops answering, when the entry sets no read_timeout" do
      error, took = read_after_silence(leased_through_proxy(env), limit: 30)

      expect(error).to be_a(ActiveRecord::ActiveRecordError)
      expect(took).to be_between(5, 20)
    end

    it "keeps the read_timeout an entry sets" do
      error, took = read_after_silence(leased_through_proxy(env, read_timeout: 2), limit: 30)

      expect(error).to be_a(ActiveRecord::ActiveRecordError)
      expect(took).to be < 5
    end
  end

  describe "MySQL", skip: server("RAC_TEST_MYSQL_URL") do
    it_behaves_like "a lease no silent server holds", "RAC_TEST_MYSQL_URL"
  end

  describe "MariaDB", skip: server("RAC_TEST_MARIADB_URL") do
    it_behaves_like "a lease no silent server holds", "RAC_TEST_MARIADB_URL"
  end
end
