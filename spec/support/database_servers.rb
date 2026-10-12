# frozen_string_literal: true

# What the specs that reach a real database server share (see CONTRIBUTING.md).
module DatabaseServers
  # Yields a second session on the server at `url`, to hold a lock or end the first one's statement.
  # Closing it lets go of whatever it held.
  def second_session(url)
    stub_const("RacSecondSessionRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacSecondSessionRecord.establish_connection(url)
    yield RacSecondSessionRecord.connection_pool.checkout
  ensure
    RacSecondSessionRecord.remove_connection if defined?(RacSecondSessionRecord)
  end

  # @return [Float] the seconds the block took
  def seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end

RSpec.configure { |config| config.include DatabaseServers }
