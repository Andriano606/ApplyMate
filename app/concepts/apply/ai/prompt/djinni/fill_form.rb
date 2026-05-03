# frozen_string_literal: true

class Apply::Ai::Prompt::Djinni::FillForm < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    Роль: Ти — професійний кар'єрний консультант та експерт з написання супровідних листів.

    Завдання: На основі опису вакансії та мого досвіду (транскрипту співбесіди/резюме), заповни поля форми для подачі заявки.

    Контекст вакансії:
    PLACEHOLDER_VACANCY_CONTEXT

    Мій досвід / Співбесіда:
    PLACEHOLDER_USER_EXPERIENCE

    Список полів форми для заповнення:
    PLACEHOLDER_FORM_FIELDS
  PROMPT

  def initialize(apply)
    @apply = apply
  end

  def call
    vacancy_context = [ @apply.vacancy.description, @apply.vacancy.details ].select(&:present?).join("\n\n")
    user_experience = @apply.user_profile.cv

    inputs = @apply.form_data['inputs'] || @apply.form_data[:inputs]
    return if inputs.blank?

    fields_info = inputs.map do |input|
      input = input.with_indifferent_access
      next if input['type'] == 'file'

      line = "- #{input['name']} (#{input['tag']}#{ " type=#{input['type']}" if input['type']})"
      line += ": #{input['label']}" if input['label'].present?
      line += " (Placeholder: #{input['placeholder']})" if input['placeholder'].present?
      line += ". Current value: #{input['value']}" if input['value'].present?

      if input['type'] == 'radio' && input['options'].present?
        options_str = input['options'].map { |o| "#{o['label']}=#{o['value']}" }.join(', ')
        line += ". Options: #{options_str}. INSTRUCTION: Return the value (not label) of your chosen option."
      end

      # Add specific instructions for known fields
      case input['name']
      when 'message'
        line += '. INSTRUCTION: Мотиваційний лист. Має бути лаконічним (до 1000 символів), підкреслювати мій релевантний досвід саме для цієї вакансії.'
      when 'save_msg_template'
        line += ". INSTRUCTION: Always return 'false'."
      when 'msg_template_name'
        line += ". INSTRUCTION: Always return ''."
      when 'save_profile_cv'
        line += ". INSTRUCTION: Always return 'false'."
      when 'salary_changed'
        line += '. INSTRUCTION: Очікувана зарплата. Визнач її на основі контексту вакансії або залиш порожньою, якщо в моєму досвіді не вказано конкретну суму.'
      when 'apply'
        line += ". INSTRUCTION: Always return 'true'."
      when 'csrfmiddlewaretoken'
        line += '. INSTRUCTION: Keep current value.'
      end
      line
    end.compact.join("\n")

    PROMPT_TEMPLATE
      .sub('PLACEHOLDER_VACANCY_CONTEXT', vacancy_context)
      .sub('PLACEHOLDER_USER_EXPERIENCE', user_experience)
      .sub('PLACEHOLDER_FORM_FIELDS', fields_info)
  end
end
