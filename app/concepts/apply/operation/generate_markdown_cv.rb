# frozen_string_literal: true

class Apply::Operation::GenerateMarkdownCv < ApplyMate::Operation::Base
  PROMPT_TEMPLATE = <<~PROMPT
    STRICT RULES (Negative Constraints):
      - NO INTRODUCTIONS: Не пиши жодних вступних фраз на кшталт "Ось ваше резюме...".
      - NO OUTRO/NOTES: Не додавай жодних нотаток, пояснень чи приміток (Notes) в кінці.
      - NO META-COMMENTARY: Не пояснюй, які ключові слова ти використав або чому.
      - ONLY MARKDOWN: Результатом має бути виключно текст резюме у форматі Markdown і нічого більше.
      - DO NOT include any preamble or post-amble. Start directly with the content.

    Роль: Ти — професійний Technical Resume Writer з 15-річним досвідом у наймі для Big Tech компаній (Google, Meta, Amazon). Твоє завдання — створити ідеальне, оптимізоване під ATS резюме, яке гарантовано пройде автоматичні фільтри та отримає 95+ match score.

    Вхідні дані:
    Профіль кандидата:
    PLACEHOLDER_USER_PROFILE

    Назва вакансії: PLACEHOLDER_VACANCY_TITLE

    Опис вакансії:
    PLACEHOLDER_VACANCY_DESCRIPTION

    Інструкції зі створення:
    ATS Optimization: Використовуй ключові слова з опису вакансії, але вплітай їх природно. Використовуй стандартні заголовки секцій (Experience, Skills, Education).
    ATS-friendly Структура: Використовуй лише одну колонку. Ніяких іконок, таблиць, графіків чи складного дизайну. Тільки чистий текст, який ідеально конвертується в PDF.
    Дзеркальний метод (Keyword Matching): Проаналізуй текст вакансії. Якщо там вказано "Ruby on Rails 7+", використовуй саме таке формулювання. Не скорочуй і не змінюй назви технологій. Використовуй точні збіги ключових слів.
    Метрики та Досягнення (Quantifiable Results): Кожен пункт досвіду має містити конкретні цифри (%, $, ms, кількість користувачів). Вигадай правдоподібні досягнення, базуючись на моєму досвіді: наприклад, "зменшив час відгуку на 30%", "збільшив покриття тестами до 100%", "прискорив CI/CD у 2 рази".
    Проекти як Досвід: Якщо у мене бракує комерційного досвіду в певній технології, що є у вакансії, виділи мої складні проекти (маркетплейси, автоматизації) як повноцінні кейси в розділі "Experience", описуючи їх через бізнес-результати.
    Achievements (Quantifiable Results): Замість простого опису обов'язків, вигадай та сформулюй досягнення за моделлю Google XYZ Formula: "Виконав [X], що вимірюється через [Y], шляхом впровадження [Z]".
    Приклад: "Оптимізував час відгуку API на 40% (Y) шляхом впровадження кешування Redis та рефакторингу важких запитів (Z)".
    High-Impact Verbs: Починай кожне речення з сильних дієслів: Spearheaded, Engineered, Orchestrated, Automated, Scaled.
    Professional Summary: Напиши потужний вступ (3-4 речення), який позиціонує мене як senior-спеціаліста, що вирішує бізнес-проблеми, а не просто пише код.
    Tech Stack: Згрупуй навички за категоріями (Languages, Frameworks, Tools, Cloud/DevOps), щоб вони легко зчитувалися і ботами, і людьми.
    Тон та стиль:
    Використовуй ділову англійську мову (якщо вакансія англійською).
    Зроби акцент на масштабованості, продуктивності та архітектурних рішеннях.
    Прикрась мій досвід: якщо я працював над фічею, напиши, що я «спроектував архітектуру цієї системи». Якщо я виправляв баги, напиши, що я «підвищив стабільність системи на 25%».
    Резюме має займати не більше 2 сторінок А4 у фінальному форматі.
    Пиши тезисно щоб влізло на 2 сторінках А4.
    Не додавай мій linkedin.
    Формат виводу: Надай текст резюме у форматі Markdown. Не використовуй графіку або складні таблиці, які можуть "зламати" ATS. СУВОРА ЗАБОРОНА на будь-який супровідний текст. Не пиши "Ось ваше резюме..." або "Я адаптував навички...". Виводь ТІЛЬКИ текст самого резюме.

    Output Constraint:
      - Починай відповідь з символів '___$$$$___' і закінчуй символами '___$$$$___'. Все, що поза цими межами, буде ігноруватися моєю системою, тому не пиши там нічого.#{' '}
      - Надай ТІЛЬКИ текст резюме у форматі Markdown.
      - Не додавай жодних вступних фраз, пояснень, висновків чи коментарів до своєї роботи.#{' '}
      - Твоя відповідь має починатися безпосередньо з імені кандидата.
      - Output ONLY the Markdown content. Do not include any conversational text, preamble, or post-analysis notes. Start directly with the candidate's name.
  PROMPT

  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    return if apply.cv_markdown.present?

    markdown = call_ai(apply)
    markdown = extract_markdown_content(markdown)
    apply.update!(cv_markdown: markdown)
  end

  private

  def extract_markdown_content(text)
    return '' if text.blank?

    if text.include?('___$$$$___')
      parts = text.split('___$$$$___')
      # Беремо другу частину (індекс 1), якщо вона існує
      return parts[1].strip if parts.size >= 2 && parts[1].strip.present?
    end

    match = text.match(/```markdown\s+(.*?)\s+```/m)
    match ? match[1].strip : text.strip
  end

  def call_ai(apply)
    client = build_client(apply.ai_integration)
    prompt = self.class.build_prompt(apply)
    client.ask(prompt)
  end

  def build_client(ai_integration)
    client_class = AiIntegration::PROVIDER_CLIENTS.fetch(ai_integration.provider)
    client_class.new(api_key: ai_integration.api_key, host: ai_integration.host, model: ai_integration.model)
  end

  def self.build_prompt(apply)
    PROMPT_TEMPLATE
      .sub('PLACEHOLDER_USER_PROFILE', apply.user_profile.cv)
      .sub('PLACEHOLDER_VACANCY_TITLE', apply.vacancy.title.to_s)
      .sub('PLACEHOLDER_VACANCY_DESCRIPTION', [ apply.vacancy.description, apply.vacancy.details ].select(&:present?).join("\n\n"))
  end
end
