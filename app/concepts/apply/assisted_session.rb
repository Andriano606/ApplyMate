# frozen_string_literal: true

# Keeps assisted-mode browsers alive between requests.
#
# An assisted session outlives the request that created it: the app fills the
# form and then waits for a person to press submit. Without a reference here the
# Ferrum object would be garbage-collected and a locally launched Chrome would
# die with it, closing the window the user was about to use.
#
# Process-local on purpose. With CHROME_HOST the actual browser lives in the
# shared chrome_vnc container, so any worker can hand the user the same window;
# without it, assisted mode is a single-process (development) convenience.
module Apply::AssistedSession
  MAX_SESSIONS = 5

  class << self
    def store(apply_id, browser)
      close_oldest if sessions.size >= MAX_SESSIONS
      close(apply_id)
      sessions[apply_id.to_i] = { browser:, opened_at: Time.current }
      browser
    end

    def fetch(apply_id)
      entry = sessions[apply_id.to_i]
      return nil if entry.nil?

      browser = entry[:browser]
      return browser if browser.alive?

      sessions.delete(apply_id.to_i)
      nil
    end

    def close(apply_id)
      entry = sessions.delete(apply_id.to_i)
      entry && quit_quietly(entry[:browser])
    end

    def open?(apply_id)
      fetch(apply_id).present?
    end

    private

    def sessions
      @sessions ||= {}
    end

    def close_oldest
      oldest = sessions.min_by { |_, entry| entry[:opened_at] }
      close(oldest.first) if oldest
    end

    def quit_quietly(browser)
      browser&.quit
    rescue StandardError => e
      Rails.logger.warn("AssistedSession: failed to quit browser: #{e.message}")
    end
  end
end
