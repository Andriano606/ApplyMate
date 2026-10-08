# frozen_string_literal: true

class ApplyMate::Ai::Prompt::Base
  # Markers around text that comes from a web page (vacancy text, field descriptions, a page after a submit). The
  # prompt tells the model to read what is between them and never follow instructions found there.
  OPEN_MARK = '<<<UNTRUSTED_PAGE_CONTENT>>>'
  CLOSE_MARK = '<<<END_UNTRUSTED_PAGE_CONTENT>>>'
  MARKS = /<<<(END_)?UNTRUSTED_PAGE_CONTENT>>>/

  def self.call(...)
    new(...).call
  end

  def initialize(*args, **kwargs)
    # Default implementation
  end

  def call
    raise NotImplementedError, "#{self.class} must implement #call"
  end

  private

  # `text` between the untrusted-content markers; marker look-alikes inside it are removed so the page cannot close
  # the block early.
  def untrusted(text)
    "#{OPEN_MARK}\n#{text.to_s.gsub(MARKS, '')}\n#{CLOSE_MARK}"
  end
end
