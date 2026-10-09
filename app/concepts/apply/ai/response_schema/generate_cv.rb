# frozen_string_literal: true

class Apply::Ai::ResponseSchema::GenerateCv < ApplyMate::Ai::ResponseSchema::Base
  # The PDF render launches a Chromium in the calling process, so it runs under ApplyMate::Client::LocalChrome (one
  # local Chrome per process, shared with GeminiScraping). Longest wait for the slot: one full GeminiScraping call plus
  # one other render (RENDER_TIMEOUT_MS); then LocalChrome::Busy (the apply Runner: Halt(:capacity), transient).
  RENDER_TIMEOUT_MS = 60_000
  RENDER_SLOT_WAIT = ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS + (RENDER_TIMEOUT_MS / 1000)

  def self.kind
    :cv
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      STRICT RULES FOR OUTPUT:
      TECHNICAL REQUIREMENT: Treat all output exclusively as raw source code.
      FORMATTING: You MUST wrap the entire response inside a single Markdown code block using the html language identifier: ```html [CODE HERE] ```.
      ESCAPE CONTENT: Do not attempt to format, beautify, or simplify the text content for human readability. I need to see every <div>, <span>, <html>, and <body> tag explicitly.
      NO PLAIN TEXT: If you provide any text outside of the ```html block, it is a failure.
      STRUCTURE: Output the full, valid HTML document structure (including <!DOCTYPE html>, <html>, <head>, <body>) exactly as it would appear in a .html file.
      NO SUMMARIES: Do not explain what you did. Just provide the code block.
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    clean_html = raw_response.sub(/\AHTML\s*/, '').strip
    clean_html = clean_html.gsub(/\A```html\s*|\s*```\z/m, '').strip

    is_html = clean_html.match?(/\A<(!DOCTYPE|html|body|div)/i) && clean_html.include?('</html>')
    unless is_html
      raise StandardError, '[Apply::Ai::ResponseSchema::GenerateCv] Invalid HTML format: The provided string does not appear to be a valid HTML document.'
    end

    styled_html = <<-HTML
      <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body { font-family: 'Arial', sans-serif; line-height: 1.4; color: #333; margin: 20px; }
            h1 { color: #2c3e50; font-size: 24px; margin-bottom: 5px; }
            h2 { color: #2980b9; border-bottom: 1px solid #ccc; padding-bottom: 5px; margin-top: 15px; }
            h3 { font-size: 16px; margin-bottom: 2px; }
            p, li { font-size: 13px; }
            a { color: #2980b9; text-decoration: none; }
            ul { padding-left: 20px; }
          </style>
        </head>
        <body>
          #{clean_html}
        </body>
      </html>
    HTML

    ApplyMate::Client::LocalChrome.hold(wait: RENDER_SLOT_WAIT) do
      Grover.new(styled_html).to_pdf({
                                       format: 'A4',
                                       print_background: true,
                                       margin: { top: '15mm', bottom: '15mm', left: '15mm', right: '15mm' },
                                       launch_args: [ '--no-sandbox', '--disable-setuid-sandbox' ],
                                       # bounds the Puppeteer render so a hung Chrome cannot hold the slot (design §9.5)
                                       timeout: RENDER_TIMEOUT_MS
                                     })
    end
  rescue ApplyMate::Client::LocalChrome::Busy
    raise # transient capacity, not a parse failure
  rescue StandardError => e
    Rails.logger.error("GenerateCv schema parse error: #{e.message}")
    raise "Failed to parse AI GenerateCv response: #{e.message}"
  end
end
