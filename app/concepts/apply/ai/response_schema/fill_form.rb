# frozen_string_literal: true

class Apply::Ai::ResponseSchema::FillForm < ApplyMate::Ai::ResponseSchema::Json
  def self.kind
    :answers
  end

  # Keys are the form's own input names, so there are no fixed properties: validated here, never
  # sent natively (native_schema? false). Any scalar is accepted, as before this schema existed:
  # Apply::Operation::Ai::FillForm stringifies each value, and fields like `apply` ("Always return
  # 'true'") or a salary may come back as JSON booleans/numbers. Nested objects/arrays would be
  # stringified into garbage, so they are rejected.
  def self.json_schema
    { type: 'object', additionalProperties: { type: %w[string number boolean null] } }
  end

  def self.format_instructions
    <<~INSTRUCTIONS
      Вимоги до формату відповіді:
      Поверни результат виключно у форматі JSON об'єкта, де ключ — це name інпуту, а значення — це текст для введення. Не додавай жодних зайвих пояснень чи Markdown оформлення (крім самого блоку коду).
      Не включай поля типу "file".
    INSTRUCTIONS
  end
end
