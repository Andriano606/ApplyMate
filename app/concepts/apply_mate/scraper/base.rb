# frozen_string_literal: true

class ApplyMate::Scraper::Base
  include ApplyMate::Logging
  def fetch_listing(page:)
    raise NotImplementedError
  end

  def fetch_description(url)
    raise NotImplementedError
  end

  def fetch_details(url)
    raise NotImplementedError
  end

  def fetch_applyble(url, session_id:)
    raise NotImplementedError
  end

  def fetch_apply_type(url, session_id:)
    raise NotImplementedError
  end

  def form_selector
    raise NotImplementedError
  end

  class TerminationError < Exception; end

  private

  def check_termination!
    return unless Thread.main.thread_variable_get(:solid_queue_terminating)

    log 'Termination signal received. Raising error...', color: :red, level: :warn
    raise TerminationError, 'Scraper terminated by system'
  end

  def full_url(path)
    return nil if path.blank?
    URI.join(@source.base_url, path).to_s
  rescue StandardError
    path
  end

  def sanitize_html(html, compact: false)
    return '' if html.blank?
    text = Html2Text.convert(html)
    return text unless compact
    text.gsub(/[\t\r\n]+/, ' ').gsub(/\s{2,}/, ' ').strip
  end
end
