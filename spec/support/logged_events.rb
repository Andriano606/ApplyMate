# frozen_string_literal: true

# Captures the JSON events ApplyMate::Logging writes for Grafana, parsed.
#
#   events = capture_logged_events
#   operation.call
#   expect(events.find { |e| e['event'] == 'vacancy_sync_finished' }).to include('result' => 'ok')
module LoggedEvents
  def capture_logged_events
    events = []
    %i[info warn error].each do |level|
      allow(Rails.logger).to receive(level).and_wrap_original do |original, *args, &block|
        line = args.first
        events << JSON.parse(line) if line.is_a?(String) && line.start_with?('{"event"')
        original.call(*args, &block)
      end
    end
    events
  end
end

RSpec.configure { |config| config.include LoggedEvents }
