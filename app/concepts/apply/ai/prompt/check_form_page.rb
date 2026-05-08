# frozen_string_literal: true

class Apply::Ai::Prompt::CheckFormPage < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    You are analyzing an HTML page from an employer's website.

    Task: Determine whether this page contains an application or contact form that a job applicant can fill in and submit. Ignore newsletter subscription forms and login forms.

    Important: elements with attribute data-hidden="true" exist in the DOM but are NOT
    currently visible to the user — they are hidden by a JavaScript framework (Vue, React,
    etc.) and will only appear after a user interaction. A form that has data-hidden="true"
    on itself or any ancestor is NOT considered an already-visible form.

    Three possible outcomes — evaluate them in this exact order:

    1. An application form is already visible and interactive (the form element and all its
       ancestors do NOT have data-hidden="true"):
       Set has_form to true, trigger_selector to null, and form_url to null.
       Also set form_selector to a CSS selector that uniquely identifies the container
       wrapping all application input fields. Use the `form` tag selector if a standard
       `<form>` element is present. Otherwise return the selector for the nearest common
       ancestor element (div, section, etc.) that contains all the inputs — use the same
       priority rules as trigger_selector (id first, then tag + distinctive attributes,
       then :nth-of-type). If you cannot determine a reliable container, set form_selector
       to null.

    2. No visible form exists, but the page has a visible button or link (without
       data-hidden="true") whose purpose is to apply for the job or send a CV (look for
       words like "Apply", "Відгукнутися", "Send CV", "Надіслати резюме", "Submit",
       "Contact us", or similar in any language):
       Set has_form to false, trigger_selector to the CSS selector of that element,
       form_url to null, and form_selector to null.
       IMPORTANT: choose outcome 2 over outcome 3 whenever such a button or link exists,
       even if you are not certain it reveals a form — prefer the interactive element.

       Selector requirements for trigger_selector — follow this priority order:
       a. If the element has an `id` attribute, use `#id-value` (always unique).
       b. Otherwise combine tag + the most distinctive attribute values (data-*, aria-*, href):
          e.g. `a[href="/jobs/123/apply"]` or `button[data-action="open-form"]`.
       c. If no distinguishing attribute exists, count the element's position among siblings
          of the same tag and append `:nth-of-type(N)` to make it unique.
          Example: if "Відгукнутися" is the 2nd `<a>` inside its parent `<div class="actions">`,
          write `.actions > a:nth-of-type(2)`.
       The selector MUST match EXACTLY ONE element. Re-read the HTML to verify before returning.

    3. No form and no apply button exist, but there is a link to a different page that
       likely contains an application form (NOT a vacancy list or job board homepage):
       Set has_form to false, trigger_selector to null, form_url to that URL
       (prefer absolute URLs), and form_selector to null.
       If no suitable URL can be found, set form_url to null.

    Page HTML:
    PLACEHOLDER_HTML
  PROMPT

  def initialize(html)
    @html = html
  end

  def call
    PROMPT_TEMPLATE.sub('PLACEHOLDER_HTML', @html.to_s.truncate(20_000))
  end
end
