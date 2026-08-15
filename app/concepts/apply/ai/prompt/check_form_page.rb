# frozen_string_literal: true

# Receives a structured page digest (Browser#page_digest) instead of raw HTML:
# every form/button/link candidate already carries a deterministic CSS selector,
# so the AI only PICKS a selector from the digest and never invents one.
class Apply::Ai::Prompt::CheckFormPage < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    You are analyzing a structured digest of a page from an employer's website.
    The digest lists the page title, headings, forms (with their field names),
    buttons and links. Every entry has a "selector" — an exact CSS selector.

    Task: Determine whether this page contains an application or contact form that
    a job applicant can fill in and submit. Ignore newsletter subscription forms,
    search forms and login forms (password fields, "sign in" wording).

    Important: entries with "hidden": true exist in the DOM but are NOT currently
    visible — they will only appear after a user interaction. A hidden form is NOT
    considered an already-visible form.

    Three possible outcomes — evaluate them in this exact order:

    1. A visible application form exists ("hidden": false, and its field_names look
       like an application: name/email/phone/CV/message/cover letter etc.):
       Set has_form to true, trigger_selector to null, form_url to null, and
       form_selector to that form's "selector" value COPIED EXACTLY from the digest.
       If the digest has no forms but "fields_container" is present and its
       field_names look like an application form, use fields_container.selector.

    2. No visible application form, but a visible button or link ("hidden": false)
       whose text means applying for the job or sending a CV (e.g. "Apply",
       "Відгукнутися", "Send CV", "Надіслати резюме", "Submit application",
       "Contact us" or similar in any language):
       Set has_form to false, trigger_selector to that entry's "selector" value
       COPIED EXACTLY, form_url to null, and form_selector to null.
       Prefer this outcome over outcome 3 whenever such a button or link exists.

    3. No form and no apply button, but a link likely leads to a page with an
       application form (NOT a vacancy list or the site's homepage):
       Set has_form to false, trigger_selector to null, form_url to that link's
       "href" value, and form_selector to null.
       If no suitable link exists, set form_url to null.

    Never construct a selector yourself — only copy a "selector" value that is
    present in the digest.

    Page digest (JSON):
    PLACEHOLDER_DIGEST
  PROMPT

  def initialize(digest)
    @digest = digest
  end

  def call
    PROMPT_TEMPLATE.sub('PLACEHOLDER_DIGEST', JSON.generate(@digest.to_h).truncate(20_000))
  end
end
