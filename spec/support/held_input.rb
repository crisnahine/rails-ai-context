# frozen_string_literal: true

require "json"

# Sends request lines the way a client does: the server's input stays open until every request with an id has
# its reply, since a server whose input ends gives calls still waiting on a booting app only a short grace.
module HeldInput
  # Far above any cold boot, so a server that never answers still fails the example.
  REPLY_WAIT = 180

  # Returns what the server wrote, once each id asked has a reply or the output ended, with the input closed.
  def self.exchange(input, output, lines, wait: REPLY_WAIT)
    asked = lines.filter_map { |line| id_of(line, "method") }
    text = +""
    ended = false
    lock = Mutex.new
    replied = ConditionVariable.new
    reader = Thread.new do
      output.each_line do |line|
        lock.synchronize do
          text << line
          # One reply answers one request, so a repeated id waits for as many replies.
          index = asked.index(id_of(line))
          asked.delete_at(index) if index
          replied.signal
        end
      end
    ensure
      lock.synchronize do
        ended = true
        replied.signal
      end
    end
    begin
      input.write(lines.join)
      input.flush
    rescue Errno::EPIPE, IOError
      nil
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    lock.synchronize do
      until asked.empty? || ended
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if left <= 0

        replied.wait(lock, left)
      end
    end
    input.close
    reader.join
    text
  end

  # The id a line carries, a request's only where it also names a method.
  def self.id_of(line, *needed)
    message = JSON.parse(line)
    message["id"] if message.is_a?(Hash) && message.key?("id") && needed.all? { |key| message.key?(key) }
  rescue JSON::ParserError
    nil
  end
end
