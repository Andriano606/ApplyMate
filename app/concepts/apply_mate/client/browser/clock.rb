# The one time source of the browser layer: monotonic milliseconds for waits and polls, wall-clock Time for the
# scope deadline (Session.open receives a Time). Specs stub .now_ms/.sleep_ms to drive the wait loops.
module ApplyMate::Client::Browser::Clock
  def self.now_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
  end

  def self.sleep_ms(milliseconds)
    sleep(milliseconds / 1000.0)
  end

  def self.remaining_ms(deadline)
    ((deadline - Time.current) * 1000).floor
  end
end
