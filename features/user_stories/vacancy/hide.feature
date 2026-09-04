Feature: Hiding vacancies
  A vacancy the user has looked at and rejected can be hidden. The card stays in
  place, blurred, and offers a restore button on hover — also after a reload.
  Hiding is a personal marker: it does not change search results or the
  appeared/disappeared counters of saved filters.

  Background:
    Given the OAuth user is "Andrii" with email "andrii@example.com"
    And a job source exists
    And the last Source has the following Vacancy records:
      | external_id | title            | company_name | description       |
      | ruby-1      | Ruby Developer   | Acme         | We need a backend |
      | python-1    | Python Developer | Acme         | We need data work |
    And the vacancy search index is refreshed

  Scenario: Hiding a vacancy blurs its card and keeps it blurred after a reload
    Given I am logged in as Andrii Kuluev
    When I visit the home page
    And I click "Приховати" on the vacancy card "Ruby Developer"
    Then the vacancy card "Ruby Developer" is hidden
    And the vacancy card "Python Developer" is not hidden
    When I visit the home page
    Then the vacancy card "Ruby Developer" is hidden
    And the vacancy card "Python Developer" is not hidden

  Scenario: Hiding a vacancy leaves the saved filter counters untouched
    Given I am logged in as Andrii Kuluev
    And the last User has the following SavedFilter records:
      | name    | include_tags | include_ops | exclude_tags |
      | Backend | ["ruby"]     | []          | []           |
    When I visit the Vacancy index page
    And I click on "Backend"
    And the SavedFilter with name "Backend" record should have:
      | last_seen_count | 1 |
    And I click "Приховати" on the vacancy card "Ruby Developer"
    Then the vacancy card "Ruby Developer" is hidden
    When I visit the Vacancy index page
    Then the preset "Backend" shows "1"
    And the preset "Backend" shows no deltas

  Scenario: Hovering a hidden card reveals a button that restores the vacancy
    Given I am logged in as Andrii Kuluev
    When I visit the home page
    And I click "Приховати" on the vacancy card "Ruby Developer"
    Then the vacancy card "Ruby Developer" is hidden
    And I do not see button "Повернути"
    When I hover over the vacancy card "Ruby Developer"
    Then I see button "Повернути"
    When I click "Повернути" on the vacancy card "Ruby Developer"
    Then the vacancy card "Ruby Developer" is not hidden
    When I visit the home page
    Then I see text "Ruby Developer"

  Scenario: A guest cannot hide vacancies
    When I visit the home page
    Then I see text "Ruby Developer"
    And I do not see button "Приховати"
