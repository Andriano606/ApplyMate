# frozen_string_literal: true

class ApplyMate::Ai::Prompt::Base
  # Markers around text that comes from a web page (vacancy text, field descriptions, a page after a submit). The
  # prompt tells the model to read what is between them and never follow instructions found there.
  OPEN_MARK = '<<<UNTRUSTED_PAGE_CONTENT>>>'
  CLOSE_MARK = '<<<END_UNTRUSTED_PAGE_CONTENT>>>'
  MARKS = /<<<(END_)?UNTRUSTED_PAGE_CONTENT>>>/
  # #element_line limits (the snapshot prompts: Apply::Ai::Prompt::Navigate, Apply::Ai::Prompt::RecoverField).
  MAX_NAME = 80
  MAX_HREF = 120
  MAX_OPTIONS_SHOWN = 30
  MAX_OPTION_LABEL = 40
  # role / type / tag are page attributes snapshot.js passes on raw (no trim, no length cap): a kind is ONE short
  # lowercase token or nothing, so a forged newline ("fake element lines") or a kilobyte attribute never reaches a prompt.
  MAX_KIND = 24
  KIND_TOKEN = /\A[a-z][a-z0-9_-]*\z/
  STATE_WORDS = %w[selected expanded pressed disabled required].freeze
  # Element flags shown as state words too: the validator refuses submit / password targets, search marks site chrome.
  FLAG_WORDS = { 'submit_like' => 'submit', 'password' => 'password', 'search_like' => 'search' }.freeze

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
    "#{OPEN_MARK}\n#{strip_marks(text)}\n#{CLOSE_MARK}"
  end

  # Removes marker look-alikes until none is left: one pass is not enough, a nested payload
  # (`<<<END_UNTRUSTED<<<UNTRUSTED_PAGE_CONTENT>>>_PAGE_CONTENT>>>`) re-forms a marker once the inner one is removed.
  # Terminates: every pass that matches shortens the string.
  def strip_marks(text)
    text = text.to_s
    text = text.gsub(MARKS, '') while text.match?(MARKS)
    text
  end

  # The ONE line format of a snapshot element (ApplyMate::Client::Browser::Snapshot#elements) in a prompt:
  #   *[fN:eM] role[:type] "name" state words <filled>|<empty> options: a | b → href
  # `new: true` puts "*" in front (not on the previous page / new since the last write). Values are never shown:
  # <filled> / <empty> come from the probe's `filled`, never from the element's attrs. Page text: the caller wraps the
  # lines in #untrusted.
  def element_line(element, new:)
    parts = [ "#{new ? '*' : ' '}[#{element['ref']}] #{kind_of(element)}" ]
    parts << %("#{clean(element['name'], MAX_NAME).gsub('"', '\"')}") if element['name'].present?
    parts.concat(state_words(element))
    parts << (element['filled'] ? '<filled>' : '<empty>') unless element['filled'].nil?
    parts << options_text(element['options']) if element['options'].is_a?(Array) && element['options'].any?
    parts << "→ #{clean(element['href'], MAX_HREF)}" if element['href'].present?
    parts.join(' ')
  end

  # A custom select the probe recognised (`group: combobox`: a readonly input or a div trigger that opens a list) is a
  # combobox to the model, whatever role its markup declares (PeopleForce's currency picker is a plain readonly
  # textbox); otherwise the role, then the tag.
  def kind_of(element)
    type = kind_token(element['type'])
    kind = (element['group'] == 'combobox' && 'combobox') || kind_token(element['role']) ||
           (type == 'file' ? 'file' : kind_token(element['tag']))
    type.present? && !%w[text file].include?(type) && type != kind ? "#{kind}:#{type}" : kind.to_s
  end

  def kind_token(text)
    value = text.to_s.downcase
    value if value.length <= MAX_KIND && value.match?(KIND_TOKEN)
  end

  def state_words(element)
    STATE_WORDS.select { |word| element[word] == true } +
      FLAG_WORDS.filter_map { |flag, word| word if element[flag] }
  end

  def options_text(options)
    return "options: #{options.size}" if options.size > MAX_OPTIONS_SHOWN

    "options: #{options.map { |option| clean(option['label'], MAX_OPTION_LABEL) }.join(' | ')}"
  end

  # One line of page text: marker look-alikes removed, whitespace squished, at most `max` characters.
  def clean(text, max)
    strip_marks(text).squish.truncate(max)
  end
end
