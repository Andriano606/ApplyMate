# frozen_string_literal: true

class Apply::Ai::ResponseSchema::Djinni::FillForm < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Вимоги до формату відповіді:
      Поверни результат виключно у форматі JSON об'єкта, де ключ — це name інпуту, а значення — це текст для введення. Не додавай жодних зайвих пояснень чи Markdown оформлення (крім самого блоку коду).
      Не включай поля типу "file".
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    return {} if raw_response.blank?

    # Try to find JSON block in markdown
    match = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response

    # Extract everything from the first { to the last }
    json_match = json_str.match(/(\{.*\}|\[.*\])/m)
    json_str = json_match ? json_match[0] : json_str

    begin
      JSON.parse(json_str).with_indifferent_access
    rescue StandardError => e
      Rails.logger.error("Failed to parse AI response: #{e.message}")
      raise "Failed to parse AI response: #{e.message}"
    end
  end
end
