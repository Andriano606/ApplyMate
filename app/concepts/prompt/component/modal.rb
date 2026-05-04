# frozen_string_literal: true

class Prompt::Component::Modal < ApplyMate::Component::Base
  PROMPT_TYPE_UI = {
    'fill_form'   => { icon_name: :clipboard_list },
    'generate_cv' => { icon_name: :printer }
  }.freeze

  def initialize(prompt:, **)
    @prompt = prompt
  end

  private

  def required_placeholders
    Prompt::REQUIRED_PLACEHOLDERS[@prompt.prompt_type.to_s] || []
  end
end
