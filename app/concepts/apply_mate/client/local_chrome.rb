# frozen_string_literal: true

# The process-wide bound on local Chrome processes: AT MOST ONE at a time per Ruby process. Two things launch one:
# ApplyMate::Ai::Client::GeminiScraping (a Ferrum Chrome per AI call, up to its CALL_SECONDS) and the Grover PDF render
# of Apply::Ai::ResponseSchema::GenerateCv (a puppeteer Chromium per CV, up to its 60 s render timeout). Every job that
# does either runs on the :apply queue, i.e. in the one apply worker process (config/queue.yml), whose APPLY_SLOTS
# threads may each hold a browserd lease at the same time; this slot keeps that container at APPLY_SLOTS Playwright
# clients + 1 Chrome (sizing: .ai/docs/apply_engine.md "Resource model", browser.md "Staging").
#
#   ApplyMate::Client::LocalChrome.hold(wait: seconds) { launch, use and quit the Chrome }
#
# Termination: a holder waits at most `wait` seconds (a negative wait is not attempted), then Busy; the block runs
# under the slot and the slot is released in ensure whatever the block raises.
class ApplyMate::Client::LocalChrome
  # The slot stayed taken for the caller's whole wait. Transient: the apply Runner maps it to Halt(:capacity) (one
  # auto-resume), the AI jobs retry it.
  class Busy < StandardError; end

  SLOT = Concurrent::Semaphore.new(1)

  def self.hold(wait:)
    raise Busy, "the local Chrome slot stayed taken (#{wait.round} s waited)" unless wait >= 0 && SLOT.try_acquire(1, wait)

    begin
      yield
    ensure
      SLOT.release
    end
  end
end
