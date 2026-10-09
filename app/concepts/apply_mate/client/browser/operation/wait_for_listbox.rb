# frozen_string_literal: true

# Session#wait_for_listbox: polls Operation::ReadListbox (the field's frame and the top document) every POLL_MS
# until options that are new since the mark (Session#dom_mark) appear. model = [Option(label, target)] without
# disabled options, or [] at min(timeout_ms, time left before the deadline): nothing opening is an answer, not an
# error. Termination: the budget check after every poll.
class ApplyMate::Client::Browser::Operation::WaitForListbox < ApplyMate::Operation::Base
  Option = Data.define(:label, :target)

  POLL_MS = 100

  def perform!(driver:, since:, timeout_ms:, **)
    skip_authorize
    budget_ms = [ timeout_ms, driver.remaining_ms ].min
    started_at = clock.now_ms
    loop do
      options = read(driver, since)
      break self.model = options if options.any?

      elapsed = clock.now_ms - started_at
      break self.model = [] if elapsed >= budget_ms

      clock.sleep_ms((budget_ms - elapsed).clamp(1, POLL_MS))
    end
  end

  private

  def read(driver, since)
    reads = ApplyMate::Client::Browser::Operation::ReadListbox
            .call(driver:, frame_path: since.fetch(:frame_path), since: since.fetch(:containers)).model
    reads.values.flat_map { |scope| scope['options'] }.reject { |option| option['disabled'] }.map do |option|
      Option.new(label: option['label'], target: option['target'])
    end
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
