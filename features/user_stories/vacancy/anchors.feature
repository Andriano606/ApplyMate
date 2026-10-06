Feature: In-page anchors on the vacancy page
  Links to an apply or a CV open and scroll to that card. A link to a whole
  section only scrolls there, and later tab switches never pull the page back.

  Background:
    Given a job source exists
    And the last Source has the following Vacancy records:
      | external_id | title          | company_name | description  |
      | ruby-1      | Ruby Developer | Acme         | Backend role |
    And I am logged in as Andrii Kuluev
    And I have a "completed" apply with a CV for the last Vacancy
    And I have a generated CV for the last Vacancy

  Scenario: The section navigation does not expand a CV
    When I visit the show Vacancy page
    Then I see the last VacancyCv
    When I click on "Резюме" in the vacancy page navigation
    Then the vacancy page is at the "vacancy-cvs" anchor
    And the CV of the last Apply is collapsed
    And the last VacancyCv is collapsed

  Scenario: Switching a tab does not reopen the CV the URL points at
    When I visit the show Vacancy page
    Then I see the last VacancyCv
    When I click on "Перейти до резюме"
    Then the vacancy page is at the CV of the last Apply
    And the CV of the last Apply is expanded
    When I collapse the CV of the last Apply
    And I expand the last VacancyCv
    And I click on "Промпт" in the last VacancyCv
    Then the CV of the last Apply is collapsed
