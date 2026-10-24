# frozen_string_literal: true

# A `:cpu_timed` example measures the CPU a call spends, so a loaded machine does not fail it.
module CpuTimed
  # Windows has no process CPU clock; the bound is measured on whichever clock times the call.
  def cpu_clock
    Process.const_defined?(:CLOCK_PROCESS_CPUTIME_ID) ? Process::CLOCK_PROCESS_CPUTIME_ID : Process::CLOCK_MONOTONIC
  end

  def cpu_seconds
    started = Process.clock_gettime(cpu_clock)
    yield
    Process.clock_gettime(cpu_clock) - started
  end
end

RSpec.configure do |config|
  config.include CpuTimed, :cpu_timed

  # Regexp.timeout counts wall time, so on a loaded machine it ends a match that did little work.
  config.around(:each, :cpu_timed) do |example|
    next example.run unless Regexp.respond_to?(:timeout=)

    saved = Regexp.timeout
    Regexp.timeout = nil
    example.run
  ensure
    Regexp.timeout = saved if Regexp.respond_to?(:timeout=)
  end
end
