Feature: Saved filter counters
  Each preset pill shows how many vacancies it matches now, plus how many
  appeared or disappeared since the user last opened that preset.

  Background:
    Given the OAuth user is "Andrii" with email "andrii@example.com"
    And I am logged in as Andrii Kuluev
    And a job source exists
    And the last Source has the following Vacancy records:
      | external_id | title             | company_name | description       |
      | ruby-1      | Ruby Developer    | Acme         | We need a backend |
      | python-1    | Python Developer  | Acme         | We need data work |
    And the vacancy search index is refreshed
    And the last User has the following SavedFilter records:
      | name    | include_tags | include_ops | exclude_tags |
      | Backend | ["ruby"]     | []          | []           |
      | Data    | ["python"]   | []          | []           |
    When I visit the Vacancy index page
    # A pill click is a Turbo frame visit — wait for its snapshot to land before
    # clicking the next one, otherwise the two visits race.
    And I click on "Backend"
    And the SavedFilter with name "Backend" record should have:
      | last_seen_count | 1 |
    And I click on "Data"
    And the SavedFilter with name "Data" record should have:
      | last_seen_count | 1 |
    And the last Source has the following Vacancy records:
      | external_id | title            | company_name | description       |
      | ruby-2      | Ruby Engineer    | Acme         | We need a backend |
      | python-2    | Python Engineer  | Acme         | We need data work |
    And the vacancy search index is refreshed
    And I visit the Vacancy index page

  Scenario: Every preset reports the vacancies that appeared since it was opened
    Then the preset "Backend" shows "+1"
    And the preset "Data" shows "+1"

  Scenario: Opening a preset clears its own counters only
    When I click on "Backend"
    # Asserted first: it only holds once the clicked response has replaced the row.
    Then the preset "Backend" shows no deltas
    And the preset "Data" shows "+1"

  Scenario: Passing the pointer over a preset on the way does not clear its counters
    When I hover over "Data"
    And I click on "Backend"
    # Asserted first: it only holds once the clicked response has replaced the row.
    Then the preset "Backend" shows no deltas
    And the preset "Data" shows "+1"
