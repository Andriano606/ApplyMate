# frozen_string_literal: true

# Opens a URL in the session (Session#goto: PublicAddressGuard, then navigation and the Cloudflare wait). The URL is a
# template (Base::TEMPLATES): it must start with a {placeholder} and hold no literal URL, so a recipe never carries a
# site the run did not reach on its own. A placeholder without a value at perform time raises ArgumentError (a broken
# adapter, not a site anomaly).
class Apply::Recipe::Op::Goto < Apply::Recipe::Op::Base
  LITERAL_URL = %r{://}
  TEMPLATE_START = /\A#{PLACEHOLDER}/

  def self.attributes
    %w[url_template]
  end

  def self.from_h(attrs)
    new(url_template: attrs.fetch('url_template'))
  end

  attr_reader :url_template

  def initialize(url_template:)
    template = url_template.to_s
    unknown = template.scan(PLACEHOLDER).flatten - TEMPLATES.keys
    raise ArgumentError, "unknown url_template placeholder(s) #{unknown.join(', ')}" if unknown.any?
    if template.match?(LITERAL_URL) || !template.match?(TEMPLATE_START)
      raise ArgumentError, "url_template #{template.inspect} is not a template (URL templates only: start with a {placeholder})"
    end

    @url_template = template
  end

  def perform!(ctx)
    ctx.session.goto(url(ctx))
  end

  def gate_event
    :after_goto
  end

  def to_h
    head('url_template' => url_template)
  end

  # The URL this op opens in `ctx`'s run.
  def url(ctx)
    url_template.gsub(PLACEHOLDER) do
      name = Regexp.last_match(1)
      TEMPLATES.fetch(name).call(ctx).presence || raise(ArgumentError, "recipe placeholder {#{name}} has no value")
    end
  end
end
