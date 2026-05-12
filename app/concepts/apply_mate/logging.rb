# frozen_string_literal: true

module ApplyMate::Logging
  COLORS = {
    yellow: "\e[33m",
    green:  "\e[32m",
    red:    "\e[31m",
    cyan:   "\e[36m"
  }.freeze
  RESET = "\e[0m"

  # log "message"                    → yellow  info
  # log "message", color: :green     → green   info
  # log "message", level: :warn      → yellow  warn
  def log(message, color: :yellow, level: :info)
    code = COLORS.fetch(color, COLORS[:yellow])
    tag  = self.class.name
    Rails.logger.public_send(level, "#{code}[#{tag}] #{message}#{RESET}")
  end

  # Measures wall-clock time of the block and logs it. Returns the block result.
  # Uses CLOCK_MONOTONIC — safe with fibers (measures real elapsed time, not CPU time).
  #
  #   result = log_time("Validation") { validate(candidates) }
  #   # → [FetchProxies] Validation — 47.312s
  def log_time(label, color: :cyan, level: :info)
    t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    log("#{label} — #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s", color: color, level: level)
    result
  end
end
