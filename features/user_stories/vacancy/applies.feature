Feature: My applies on the vacancy page
  There is no separate apply page: every apply of the signed-in user is shown
  on the vacancy it was sent to, with its live status and the form the AI filled.
  Old links to an apply land on its card on the vacancy page.

  Background:
    Given a job source exists
    And the last Source has the following Vacancy records:
      | external_id | title          | company_name | description  |
      | ruby-1      | Ruby Developer | Acme         | Backend role |
    And I am logged in as Andrii Kuluev

  Scenario: The vacancy page shows my apply with the filled form
    Given I have a "completed" apply for the last Vacancy with the filled form:
      | name  | tag      | type     | label                       | value           |
      | why   | textarea | textarea | Why do you want to join us? | I love Ruby     |
      | email | input    | email    | Email                       | dev@example.com |
    When I visit the show Vacancy page
    Then I see text "Відгук надіслано"
    And the last Apply card shows status "Завершено"
    And the last Apply card shows the field "Why do you want to join us?" filled with "I love Ruby"
    And the last Apply card shows the field "Email" filled with "dev@example.com"

  Scenario: Opening an apply link lands on its card on the vacancy page
    Given I have a "failed_sending_cv" apply for the last Vacancy
    When I visit the show Apply page
    Then I am on the vacancy page at the last Apply card
    And I see text "Ruby Developer"
    And the last Apply card shows status "Помилка надсилання"
