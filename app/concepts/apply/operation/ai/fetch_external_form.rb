# frozen_string_literal: true

# Legacy external-form discovery (deleted in phase 3b): renders the vacancy's external URL in a browserd
# Session (Camoufox, trusted input), asks the AI whether the page holds the form, follows the AI's trigger
# (click) or form URL (HTTP), and stores the extracted form in apply.form_data.
#
# The Session is held only while the page is needed (render, AI check, trigger click); the form_url branch,
# the second AI check and the extraction run after the lease is released.
class Apply::Operation::Ai::FetchExternalForm < Apply::Operation::Base
  include Apply::Operation::FormExtractor

  STRIP_SELECTORS = %w[script style link noscript header nav aside iframe svg].freeze
  # Seconds to wait for the form to render after the trigger click; a timeout is ignored (the AI re-check decides).
  FORM_READY_TIMEOUT_S = 10

  stage :fetch_form

  private

  def run!(apply:, ctx:, **)
    external_url = apply.vacancy.external_url
    halt!(:no_application_path, detail: 'no external url') if external_url.blank?

    page_url, doc, cookies, check_result, trigger_selector = render_with_browser(apply, ctx, external_url)
    form_selector = check_result['form_selector'].presence

    unless check_result['has_form']
      if trigger_selector.nil?
        halt!(:not_a_form, detail: 'AI could not locate an application form page') if check_result['form_url'].blank?

        page_url, doc, cookies = http_fetch_and_parse(resolve_url(check_result['form_url'], page_url))
      end

      form_selector = check_form_page(apply, doc)['form_selector'].presence
    end

    form_data = extract_form_data(doc, page_url, cookies, selector: form_selector || 'form')
    form_data['external_url']     = external_url
    form_data['trigger_selector'] = trigger_selector if trigger_selector.present?

    apply.update!(form_data: form_data)
    # The form's open questions become "ask about it" suggestions on the vacancy page.
    VacancyQuestion::TurboHandler::Index.broadcast(apply.vacancy, apply.user)
  end

  # model: [page_url, doc, cookies, first AI check, trigger selector or nil]. The trigger is clicked only when
  # the AI found no form but named one (it wins over form_url, as before).
  def render_with_browser(apply, ctx, url)
    session_class = ApplyMate::Client::Browser::Session
    session_class.open(deadline: ctx.scope_deadline, owner: session_class.owner_for(apply), humanize: false,
                       identity: apply.hashid) do |session|
      page_url, doc, cookies = browser_fetch_and_parse(session, url)
      check_result = check_form_page(apply, doc)
      trigger = check_result['trigger_selector'].presence unless check_result['has_form']
      next [ page_url, doc, cookies, check_result, nil ] if trigger.nil?

      form_selector = check_result['form_selector'].presence || 'form'
      [ *browser_click_and_parse(session, url, trigger, form_selector), check_result, trigger ]
    end
  end

  def check_form_page(apply, doc)
    ApplyMate::Ai::AiHandler.call(
      prompt_instance:       Apply::Ai::Prompt::CheckFormPage.new(minimize_html(doc)),
      response_schema_class: Apply::Ai::ResponseSchema::CheckFormPage,
      ai_integration:        apply.ai_integration
    )
  end

  def browser_fetch_and_parse(session, url)
    session.goto(url)
    body = session.html
    halt!(:target_not_found, detail: "empty page: #{url}") if body.blank?

    [ session.current_url, Nokogiri::HTML(body), session.cookies ]
  end

  # The stored trigger_selector is the AI's selector as-is (the old uniquePath rewrite is gone): Session#click
  # accepts it only when it matches exactly one visible element, here and again at submit time.
  def browser_click_and_parse(session, url, selector, form_selector)
    session.goto(url)
    begin
      session.click(ApplyMate::Client::Browser::Target.css(selector))
    rescue ApplyMate::Client::Browser::TargetNotFound
      halt!(:target_not_found, detail: "trigger revealed nothing: #{selector}")
    end
    session.settle(:click)
    session.ready?(ApplyMate::Client::Browser::Target.css(form_selector), timeout: FORM_READY_TIMEOUT_S)

    body = session.html
    halt!(:target_not_found, detail: "trigger revealed nothing: #{selector}") if body.blank?

    [ session.current_url, Nokogiri::HTML(body), session.cookies ]
  end

  # form_url comes from the AI, so it passes the PublicAddressGuard first (UnsafeUrlError -> private_address via
  # the Runner). Redirects followed by AsyncHttp are not re-checked; this step is deleted in phase 3b.
  def http_fetch_and_parse(url)
    ApplyMate::Net::Operation::ResolvePublicAddress.call(url:)
    response = ApplyMate::Client::AsyncHttp.new.get(url, follow_redirects: true)
    halt!(:target_not_found, detail: "empty page: #{url}") if response.nil? || response.body.blank?

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
