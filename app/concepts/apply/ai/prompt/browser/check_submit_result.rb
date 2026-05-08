# frozen_string_literal: true

class Apply::Ai::Prompt::Browser::CheckSubmitResult < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    You are verifying whether a job application form was successfully submitted.

    Analyse the HTML snapshot of the page captured immediately after clicking the submit button.
    Determine whether the submission succeeded or failed.

    Signs of SUCCESS (any one is enough):
    - A confirmation message, "thank you", "application received", "we'll be in touch", or similar
    - A success notification or checkmark present in the HTML
    - The form element is gone and a success state is shown
    - The page redirected to a confirmation or profile page

    Signs of FAILURE (any one is enough):
    - Validation error messages or aria-invalid / error class attributes on fields
    - The form is still present with explicit error indicators
    - An error message or alert element in the HTML

    If the HTML is ambiguous (e.g. a blank page, a loading spinner, or unchanged form with no errors),
    assume SUCCESS — the page may still be loading after a successful submit.

    Page HTML snapshot:
    PLACEHOLDER_HTML
  PROMPT

  def initialize(html)
    @html = html
  end

  def call
    PROMPT_TEMPLATE.sub('PLACEHOLDER_HTML', @html.to_s.truncate(5_000))
  end
end
