# frozen_string_literal: true

# Generates free-text values for the fields ResolveValues could not answer
# deterministically (cover letter + unanswered custom questions). Field
# instructions derive from canonical roles — no job-board-specific names here.
# PROMPT_TEMPLATE and its placeholders are public contract: Prompt::Operation::New
# seeds user-editable templates from it (apply.fill_form_prompt).
class Apply::Ai::Prompt::FillForm < ApplyMate::Ai::Prompt::Base
  PROMPT_TEMPLATE = <<~PROMPT
    Роль: Ти — професійний кар'єрний консультант та експерт з написання супровідних листів.

    Завдання: На основі опису вакансії та мого досвіду (транскрипту співбесіди/резюме), заповни перелічені поля форми для подачі заявки.

    Контекст вакансії:
    PLACEHOLDER_VACANCY_CONTEXT

    Мій досвід / Співбесіда:
    PLACEHOLDER_USER_EXPERIENCE

    Список полів форми для заповнення (кожне починається зі свого id у квадратних дужках):
    PLACEHOLDER_FORM_FIELDS
  PROMPT

  ROLE_INSTRUCTIONS = {
    'cover_letter'        => 'Мотиваційний лист. Має бути лаконічним (до 1000 символів), ' \
                             'підкреслювати мій релевантний досвід саме для цієї вакансії.',
    'salary_expectation'  => 'Очікувана зарплата. Визнач її на основі контексту вакансії або ' \
                             'залиш порожньою, якщо в моєму досвіді не вказано конкретну суму.',
    'custom_question'     => 'Дай коротку і конкретну відповідь на це питання анкети від першої особи.'
  }.freeze

  def initialize(apply, fields = nil)
    @apply  = apply
    @fields = fields
  end

  def call
    fields = Array(@fields)
    return if fields.blank?

    vacancy_context = [ @apply.vacancy.description, @apply.vacancy.details ].select(&:present?).join("\n\n")
    fields_info     = fields.map { |field| render_field(field.to_h.stringify_keys) }.join("\n")

    template
      .sub('PLACEHOLDER_VACANCY_CONTEXT', vacancy_context)
      .sub('PLACEHOLDER_USER_EXPERIENCE', @apply.user_profile.cv)
      .sub('PLACEHOLDER_FORM_FIELDS', fields_info)
  end

  private

  def render_field(field)
    line = "- [#{field['fingerprint']}] #{field['accessible_name'].presence || field['label'].presence || field['name']}"
    line += " (#{field['tag']}#{", type=#{field['type']}" if field['type'].present?})"
    line += " (Placeholder: #{field['placeholder']})" if field['placeholder'].present?
    line += ". Current value: #{field['value']}" if field['value'].present?

    if field['options'].present?
      options_str = field['options'].map { |o| "#{o['label']}=#{o['value']}" }.join(', ')
      line += ". Options: #{options_str}. INSTRUCTION: Return the value (not label) of your chosen option."
    end

    instruction = ROLE_INSTRUCTIONS[field['role'].to_s] || ROLE_INSTRUCTIONS['custom_question']
    "#{line}. INSTRUCTION: #{instruction}"
  end

  def template
    @apply.fill_form_prompt&.content || PROMPT_TEMPLATE
  end
end
