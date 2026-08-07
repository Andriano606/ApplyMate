# frozen_string_literal: true

class VacancyQuestion::Ai::ResponseSchema::AnswerQuestion < ApplyMate::Ai::ResponseSchema::Base
  def self.format_instructions
    <<~INSTRUCTIONS
      Вимоги до формату відповіді:
      Поверни результат виключно у форматі JSON об'єкта, де ключ — це name інпуту ("answer"), а значення — це текст для введення. Не додавай жодних зайвих пояснень чи Markdown оформлення (крім самого блоку коду).
    INSTRUCTIONS
  end

  def self.extract(raw_response)
    raise 'Empty AI AnswerQuestion response' if raw_response.blank?

    match    = raw_response.match(/```json\s+(.*?)\s+```/m)
    json_str = match ? match[1] : raw_response

    json_match = json_str.match(/(\{.*\}|\[.*\])/m)
    json_str   = json_match ? json_match[0] : json_str

    answer = JSON.parse(json_str).with_indifferent_access[:answer].to_s
    raise 'AI AnswerQuestion response has no answer' if answer.blank?

    answer
  rescue StandardError => e
    Rails.logger.error("AnswerQuestion schema parse error: #{e.message}")
    raise "Failed to parse AI AnswerQuestion response: #{e.message}"
  end
end
