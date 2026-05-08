# frozen_string_literal: true

class Apply::Ai::ResponseSchema::FillForm < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Вимоги до формату відповіді:
      Поверни результат виключно у форматі JSON об'єкта, де ключ — це name інпуту, а значення — це текст для введення. Не додавай жодних зайвих пояснень чи Markdown оформлення (крім самого блоку коду).
      Не включай поля типу "file".
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return {} if raw_response.blank?

    match    = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response

    json_match = json_str.match(/(\{.*\}|\[.*\])/m)
    json_str   = json_match ? json_match[0] : json_str

    JSON.parse(json_str).with_indifferent_access
  rescue StandardError => e
    Rails.logger.error("FillForm schema parse error: #{e.message}")
    raise "Failed to parse AI FillForm response: #{e.message}"
  end
end
