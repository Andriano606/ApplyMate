# frozen_string_literal: true

class Apply::Operation::FillForm < ApplyMate::Operation::Base
  PROMPT_TEMPLATE = <<~PROMPT
    Роль: Ти — професійний кар'єрний консультант та експерт з написання супровідних листів.

    Завдання: На основі опису вакансії та мого досвіду (транскрипту співбесіди/резюме), заповни поля форми для подачі заявки.

    Контекст вакансії:
    PLACEHOLDER_VACANCY_CONTEXT

    Мій досвід / Співбесіда:
    PLACEHOLDER_USER_EXPERIENCE

    Список полів форми для заповнення:
    PLACEHOLDER_FORM_FIELDS

    Вимоги до формату відповіді:
    Поверни результат виключно у форматі JSON об'єкта, де ключ — це name інпуту, а значення — це текст для введення. Не додавай жодних зайвих пояснень чи Markdown оформлення (крім самого блоку коду).
    Не включай поля типу "file".
  PROMPT

  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    return if apply.error.present?

    return if apply.form_data.blank?

    apply.update!(status: :filling_form)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)

    ai_values_json = call_ai(apply)
    ai_values = extract_json(ai_values_json)

    if ai_values.present?
      filled_form_data = merge_ai_values(apply.form_data, ai_values)
      apply.update!(filled_form_data:, status: :pending)
    else
      apply.update!(status: :failed_filling_form, error: "AI returned empty payload or invalid JSON: #{ai_values_json}")
      raise 'Invalid AI response'
    end

    Apply::TurboHandler::StatusUpdate.broadcast(apply)
  rescue StandardError => e
    apply.update!(status: :failed_filling_form, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    raise
  end

  private

  def call_ai(apply)
    client = build_client(apply.ai_integration)
    prompt = build_prompt(apply)
    client.ask(prompt)
  end

  def build_client(ai_integration)
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider)
    client_class.new(api_key: ai_integration.api_key, host: ai_integration.host, model: ai_integration.model)
  end

  def build_prompt(apply)
    vacancy_context = [ apply.vacancy.description, apply.vacancy.details ].select(&:present?).join("\n\n")
    user_experience = apply.user_profile.cv

    inputs = apply.form_data['inputs'] || apply.form_data[:inputs]
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

  def merge_ai_values(form_data, ai_values)
    inputs = (form_data['inputs'] || form_data[:inputs] || []).map do |input|
      input = input.with_indifferent_access
      ai_value = ai_values[input['name']]
      ai_value.present? ? input.merge('value' => ai_value.to_s) : input
    end
    form_data.merge('inputs' => inputs)
  end

  def extract_json(text)
    return {} if text.blank?

    # Try to find JSON block in markdown
    match = text.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : text

    # Extract everything from the first { to the last }
    json_match = json_str.match(/(\{.*\}|\[.*\])/m)
    json_str = json_match ? json_match[0] : json_str

    JSON.parse(json_str)
  rescue JSON::ParserError
    {}
  end
end
