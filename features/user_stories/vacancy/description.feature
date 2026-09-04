Feature: Reading a vacancy description
  The scraper stores the employer's own markup, so the vacancy page shows the
  description the way it was written — paragraphs, bullet lists, bold headings —
  instead of one flattened wall of text. Only tags on the render allow-list reach
  the page: the stored copy is faithful, the rendered copy is safe.

  Background:
    Given a job source exists

  Scenario: The employer's paragraphs and bullet lists reach the page
    Given the last Source has the following Vacancy records:
      | external_id | title          | company_name | description        | description_html                                                                             |
      | ruby-1      | Ruby Developer | Acme         | Про нас Ruby Rails | <p>Про нас</p><p><strong>Вимоги</strong></p><ul><li>Ruby</li><li>Rails</li><li>Postgres</li></ul> |
    When I visit the show Vacancy page
    Then I see text "Про нас"
    And the vacancy description renders "Вимоги" in bold
    And the vacancy description renders 3 bullet points

  Scenario: Markup outside the allow-list is dropped at render time
    Given the last Source has the following Vacancy records:
      | external_id | title         | company_name | description | description_html                                    |
      | ruby-2      | Go Developer  | Acme         | Про нас     | <p>Про нас</p><script>alert(1)</script><img src="x"> |
    When I visit the show Vacancy page
    Then I see text "Про нас"
    And the vacancy description contains no "script" element
    And the vacancy description contains no "img" element

  Scenario: Vacancies scraped before markup was stored still read as paragraphs
    Given the last Source has the following Vacancy records:
      | external_id | title           | company_name | description                     |
      | ruby-3      | Rust Developer  | Acme         | Перший абзац.\n\nДругий абзац.  |
    When I visit the show Vacancy page
    Then I see text "Перший абзац."
    And I see text "Другий абзац."
