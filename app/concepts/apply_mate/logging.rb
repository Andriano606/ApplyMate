# frozen_string_literal: true

module ApplyMate::Logging
  COLORS = {
    yellow: "\e[33m",
    green:  "\e[32m",
    red:    "\e[31m",
    cyan:   "\e[36m"
  }.freeze
  RESET = "\e[0m"

  # log "message"                          → yellow info, colored text
  # log "message", color: :green           → green  info, colored text
  # log "message", level: :warn            → yellow warn, colored text
  # log("Validation") { validate(...) }    → cyan, suffixed with " — 47.312s", returns block result
  # log(event: 'proxy_done', valid: 42)    → pure JSON line for Promtail/Loki
  #
  # When a block is given, wall-clock time is measured via CLOCK_MONOTONIC
  # (safe with fibers — measures real elapsed time, not CPU time) and
  # appended to the message.
  #
  # When `event:` is given, a JSON line is emitted instead of the colored text line.
  # The file logger has ANSI stripped and no prefix, so this lands as valid JSON.
  def log(message = nil, color: nil, level: :info, event: nil, **fields)
    if event
      payload = { event: event, source: self.class.name }.merge(fields)
      if block_given?
        t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        payload[:duration_s] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
      end
      Rails.logger.public_send(level, payload.to_json)
      return result
    end

    result = nil
    if block_given?
      color ||= :cyan
      t0      = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result  = yield
      message = "#{message} — #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s"
    else
      color ||= :yellow
    end
    code = COLORS.fetch(color, COLORS[:yellow])
    tag  = self.class.name
    Rails.logger.public_send(level, "#{code}[#{tag}] #{message}#{RESET}")
    result
  end
end
