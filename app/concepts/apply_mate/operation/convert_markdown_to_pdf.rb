# frozen_string_literal: true

class ApplyMate::Operation::ConvertMarkdownToPdf < ApplyMate::Operation::Base
  def perform!(markdown:, **)
    skip_authorize

    # 1. Конвертуємо Markdown в HTML
    html_content = convert_to_html(markdown)

    # 2. Обгортаємо в базову HTML-структуру з CSS для PDF
    full_html = wrap_in_layout(html_content)

    # 3. Конвертуємо HTML в PDF байтову строку
    pdf_data = Grover.new(full_html, format: 'A4').to_pdf

    self.model = pdf_data
  end

  private

  def convert_to_html(markdown)
    renderer = Redcarpet::Render::HTML.new(hard_wrap: true, filter_html: true)
    markdown_engine = Redcarpet::Markdown.new(renderer, extensions = {
      autolink: true,
      tables: true,
      strikethrough: true,
      space_after_headers: true
    })
    markdown_engine.render(markdown)
  end

  def wrap_in_layout(html_content)
    # Важливо додати стилі, щоб PDF виглядав як резюме, а не просто текст
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="UTF-8">
          <style>
            body {#{' '}
              font-family: 'Helvetica', 'Arial', sans-serif;#{' '}
              line-height: 1.5;#{' '}
              font-size: 12pt;
              color: #333;
              margin: 0;
            }
            h1, h2, h3 { color: #000; border-bottom: 1px solid #ccc; }
            ul { padding-left: 20px; }
            li { margin-bottom: 5px; }
            @page { margin: 2cm; }
          </style>
        </head>
        <body>
          #{html_content}
        </body>
      </html>
    HTML
  end
end
