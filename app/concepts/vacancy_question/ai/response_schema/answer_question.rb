# frozen_string_literal: true

class VacancyQuestion::Ai::ResponseSchema::AnswerQuestion < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :answers
  end

  def self.json_schema
    {
      type:       'object',
      required:   %w[answer],
      properties: { answer: { type: 'string', minLength: 1 } }
    }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Вимоги до формату відповіді:
      Поверни результат виключно у форматі JSON об'єкта, де ключ — це name інпуту ("answer"), а значення — це текст для введення. Не додавай жодних зайвих пояснень чи Markdown оформлення (крім самого блоку коду).
    INSTRUCTIONS
  end

  # minLength cannot reject whitespace, and a `pattern` would break Ollama's grammar conversion
  # (llama.cpp requires anchored patterns), so a blank answer is rejected here.
  def self.extract(raw_response)
    answer = super[:answer]
    raise InvalidResponse, 'AI AnswerQuestion response has no answer' if answer.blank?

    answer
  end
end
