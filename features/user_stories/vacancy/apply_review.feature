Feature: Reviewing the answers of an application
  When the engine is not sure about the answers, the apply waits on the vacancy page.
  The user checks them, edits what is wrong and approves; the form then disappears.

  Background:
    Given a job source exists
    And the last Source has the following Vacancy records:
      | external_id | title          | company_name | description  | url                        |
      | ruby-1      | Ruby Developer | Acme         | Backend role | https://jobs.example.com/1 |
    And I am logged in as Andrii Kuluev
    And the apply engine job is not run

  Scenario: Editing an answer and approving queues the apply
    Given I have a "needs_review" apply for the last Vacancy waiting for review with the answers:
      | id  | kind | label     | value | source |
      | why | text | Why Ruby? | Money | ai     |
    When I visit the show Vacancy page
    Then I see text "Перевірте відповіді перед надсиланням"
    And I see text "AI не впевнений у частині відповідей."
    And I see text "jobs.ashbyhq.com"
    When I fill in "Why Ruby?" with "I love Ruby"
    And I click on "Підтвердити і надіслати"
    Then I see notice "Відповіді підтверджено, відгук поставлено в чергу"
    And the last Apply record should have:
      | state | queued |
    And I do not see text "Перевірте відповіді перед надсиланням"
