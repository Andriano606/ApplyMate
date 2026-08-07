# frozen_string_literal: true

class VacancyQuestion::Ai::Prompt::AnswerQuestion < ApplyMate::Ai::Prompt::Base
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

  def initialize(vacancy_question)
    @vacancy_question = vacancy_question
  end

  def call
    vacancy         = @vacancy_question.vacancy
    vacancy_context = [ vacancy.description, vacancy.details ].select(&:present?).join("\n\n")
    user_experience = @vacancy_question.user_profile.cv

    fields_info = "- answer (textarea): #{@vacancy_question.question}. " \
                  'INSTRUCTION: Дай відповідь на це питання від першої особи, спираючись на мій досвід ' \
                  'та контекст вакансії. Відповідь має бути лаконічною та по суті.'

    template
      .sub('PLACEHOLDER_VACANCY_CONTEXT', vacancy_context)
      .sub('PLACEHOLDER_USER_EXPERIENCE', user_experience)
      .sub('PLACEHOLDER_FORM_FIELDS', fields_info)
  end

  private

  def template
    @vacancy_question.fill_form_prompt&.content || PROMPT_TEMPLATE
  end
end
