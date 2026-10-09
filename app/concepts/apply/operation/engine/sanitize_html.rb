# frozen_string_literal: true

# Page HTML made inert before it is stored (failure artifacts, design §13.2): opening a stored snapshot - from the
# run timeline link or after a download - must never run the page's code (an SPA such as Ashby's reloads itself
# forever) nor fetch anything active. The ONE sanitizer for stored page HTML; CaptureArtifact runs it before Redact.
#
#   1. removed elements: script, noscript, iframe, frame, frameset, object, embed, applet, base, portal, and
#      <meta http-equiv=refresh> (any namespace: an <svg><script> goes too)
#   2. removed attributes: every on* event handler, and any attribute whose value is a javascript: / vbscript: URL
#      (whitespace and control characters ignored, as browsers do)
#   3. CSP as the first element of <head>: no script, frame, connect or form target at all; images, styles and fonts
#      may still load so the snapshot looks like the page
#
# Text and the remaining markup are kept. model = the serialized HTML (blank input is returned as is).
class Apply::Operation::Engine::SanitizeHtml < ApplyMate::Operation::Base
  CSP = "default-src 'none'; img-src data: https:; style-src 'unsafe-inline' https:; font-src https: data:"
  REMOVED_ELEMENTS = %w[script noscript iframe frame frameset object embed applet base portal].freeze
  REMOVED_XPATH = "//*[#{REMOVED_ELEMENTS.map { |name| "local-name()='#{name}'" }.join(' or ')}]".freeze
  SCRIPT_URL = /\A(?:javascript|vbscript):/i
  NOISE = /[[:space:][:cntrl:]]/

  def perform!(html:, **)
    skip_authorize
    self.model = html
    return if html.blank?

    document = Nokogiri::HTML5(html.to_s)
    document.xpath(REMOVED_XPATH).each(&:remove)
    document.xpath('//meta[@http-equiv]').each { |meta| meta.remove if meta['http-equiv'].to_s.strip.casecmp?('refresh') }
    document.xpath('//*').each { |element| strip_active_attributes(element) }
    add_csp(document)
    self.model = document.to_html
  end

  private

  def strip_active_attributes(element)
    element.attribute_nodes.each do |attribute|
      attribute.remove if attribute.name.downcase.start_with?('on') || attribute.value.gsub(NOISE, '').match?(SCRIPT_URL)
    end
  end

  # The HTML5 parser always builds <html><head>.
  def add_csp(document)
    document.at_xpath('/html/head').prepend_child(
      document.create_element('meta', 'http-equiv' => 'Content-Security-Policy', 'content' => CSP)
    )
  end
end
