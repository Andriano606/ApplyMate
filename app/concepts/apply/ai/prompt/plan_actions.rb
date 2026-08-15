# frozen_string_literal: true

# One iteration of the External::Generic loop: given the observed page state
# (fields, buttons, validation errors, alerts), the AI plans the next actions.
# For "fill" it returns the field's ROLE — never a value; values resolve through
# the answer bank / profile on our side. The AI sees no personal data here.
class Apply::Ai::Prompt::PlanActions < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    You are driving a job-application form step by step. Below is the current
    observed state of the page: form fields (with their current values),
    buttons, validation errors and alert messages. Every element has a "handle".

    Decide the next actions to move the application forward:
    - {"op": "fill", "handle": H, "role": R} — fill a field; R must be a role
      from the vocabulary below describing what the field asks for. Only plan
      fills for fields that are empty or listed in validation errors.
    - {"op": "select", "handle": H, "value": V} — choose option V (use the
      option's value, not its label) in a select/radio field.
    - {"op": "upload", "handle": H} — attach the CV file to a file field.
    - {"op": "click", "handle": H, "purpose": "next_step" | "submit"} — press a
      button to reveal the next step or submit the form. Plan at most one click
      and put it LAST.

    Role vocabulary:
    PLACEHOLDER_ROLES

    If the page cannot be automated at all, return an empty actions list with
    "status": "blocked" and a blocked_reason:
    - "captcha_v2" — a visible captcha challenge must be solved
    - "requires_account" — the site demands creating an account
    - "login_wall" — the page redirected to a login screen
    - "other" — anything else
    Otherwise use "status": "in_progress" and blocked_reason null.

    Observed state (JSON):
    PLACEHOLDER_STATE
  PROMPT

  def initialize(state)
    @state = state
  end

  def call
    PROMPT_TEMPLATE
      .sub('PLACEHOLDER_ROLES', Apply::CanonicalRoles::ALL.join(', '))
      .sub('PLACEHOLDER_STATE', JSON.generate(compact_state).truncate(20_000))
  end

  private

  # Values are truncated and file/hidden noise dropped — the AI plans actions,
  # it does not need full contents.
  def compact_state
    fields = Array(@state['fields']).map do |field|
      field = field.to_h.stringify_keys
      {
        'handle' => field['handle'], 'name' => field['name'],
        'label' => field['accessible_name'].presence || field['label'],
        'type' => field['type'], 'required' => field['required'],
        'value' => field['value'].to_s.truncate(60),
        'options' => field['options']
      }.compact
    end

    {
      'url'     => @state['url'],
      'fields'  => fields,
      'buttons' => @state['buttons'],
      'errors'  => @state['errors'],
      'alerts'  => @state['alerts']
    }
  end
end
