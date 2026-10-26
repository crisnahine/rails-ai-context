# frozen_string_literal: true

# A `:cpu_timed` example measures the CPU a call spends, so a loaded machine does not fail it.
module CpuTimed
  # The calling thread's own clock, so a thread an earlier example left running is not counted. Windows has
  # no CPU clock; the bound is measured on whichever clock times the call.
  def cpu_clock
    name = %i[CLOCK_THREAD_CPUTIME_ID CLOCK_PROCESS_CPUTIME_ID].find { |clock| Process.const_defined?(clock) }
    name ? Process.const_get(name) : Process::CLOCK_MONOTONIC
  end

  # gc: false keeps collection off for the call, for a ratio that a major GC of the suite's heap would skew.
  def cpu_seconds(gc: true)
    was_off = GC.disable unless gc
    started = Process.clock_gettime(cpu_clock)
    yield
    Process.clock_gettime(cpu_clock) - started
  ensure
    GC.enable unless gc || was_off
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
