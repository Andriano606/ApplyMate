# frozen_string_literal: true

class Apply::Operation::Ai::FetchExternalForm < Apply::Operation::Base
  include Apply::Operation::FormExtractor

  STRIP_SELECTORS = %w[script style link noscript header nav aside iframe svg].freeze

  def start_status
    :fetching_form
  end

  def error_status
    :failed_fetching_form
  end

  private

  def run!(apply:, **)
    external_url = apply.vacancy.external_url
    raise 'No external apply URL stored for this vacancy' if external_url.blank?

    @browser = ApplyMate::Client::Browser.new
    page_url, doc, cookies = browser_fetch_and_parse(@browser, external_url)

    check_result = ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::CheckFormPage.new(minimize_html(doc)),
      response_schema_class: Apply::Ai::ResponseSchema::CheckFormPage,
      ai_integration:        apply.ai_integration
    )

    trigger_selector = nil
    form_selector    = check_result['form_selector'].presence

    unless check_result['has_form']
      if check_result['trigger_selector'].present?
        page_url, doc, cookies, trigger_selector = browser_click_and_parse(
          @browser, external_url, check_result['trigger_selector']
        )
      elsif check_result['form_url'].present?
        page_url, doc, cookies = http_fetch_and_parse(ApplyMate::Client::AsyncHttp.new, check_result['form_url'])
      else
        raise 'AI could not locate an application form page'
      end

      nav_result    = ApplyMate::Ai::AiHandler.call(
        prompt_instance:       Apply::Ai::Prompt::CheckFormPage.new(minimize_html(doc)),
        response_schema_class: Apply::Ai::ResponseSchema::CheckFormPage,
        ai_integration:        apply.ai_integration
      )
      form_selector = nav_result['form_selector'].presence
    end

    form_data = extract_form_data(doc, page_url, cookies, selector: form_selector || 'form')
    form_data['external_url']     = external_url
    form_data['trigger_selector'] = trigger_selector if trigger_selector.present?

    apply.update!(form_data: form_data)
  end

  def cleanup
    @browser&.quit
  end

  def browser_fetch_and_parse(browser, url)
    page_url, body, cookies = browser.fetch_rendered(url)
    raise "Failed to fetch page: #{url}" if body.blank?

    doc = Nokogiri::HTML(body)
    [ page_url, doc, cookies ]
  end

  def browser_click_and_parse(browser, url, selector)
    page_url, body, cookies, unique_selector = browser.click_and_fetch(url, selector)
    raise "Failed to reveal form via trigger: #{selector}" if body.blank?

    doc = Nokogiri::HTML(body)
    [ page_url, doc, cookies, unique_selector.presence || selector ]
  end

  def http_fetch_and_parse(client, url)
    response = client.get(url, follow_redirects: true)
    raise "Failed to fetch page: #{url}" if response.nil? || response.body.blank?

    cookies = extract_cookies(response.headers)
    doc     = Nokogiri::HTML(response.body)
    [ url, doc, cookies ]
  end

  def minimize_html(doc)
    working = doc.dup
    working.css(STRIP_SELECTORS.join(', ')).each(&:remove)

    # Mark hidden elements instead of removing — Vue/React apps render forms in
    # the DOM with display:none, revealed only after a trigger click.
    working.css('[style*="display:none"], [style*="display: none"]').each do |node|
      node['data-hidden'] = 'true'
    end

    working.css('[style]').each { |n| n.remove_attribute('style') }

    # Strip Vue/React component attributes (data-v-*) — pure noise for the AI.
    working.traverse do |node|
      next unless node.is_a?(Nokogiri::XML::Element)
      node.attributes.keys.select { |k| k.start_with?('data-v-') }.each { |a| node.remove_attribute(a) }
    end

    # Truncate very long attribute values (reCAPTCHA tokens, base64 blobs).
    working.css('[value]').each do |node|
      node['value'] = "#{node['value'][0, 80]}…" if node['value'].to_s.length > 80
    end

    working.to_html
  end
end
