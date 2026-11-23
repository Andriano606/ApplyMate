Feature: Saved filter counters
  Each preset pill shows how many vacancies it matches now.

  Background:
    Given the OAuth user is "Andrii" with email "andrii@example.com"
    And I am logged in as Andrii Kuluev
    And a job source exists
    And the last Source has the following Vacancy records:
      | external_id | title             | company_name | description       |
      | ruby-1      | Ruby Developer    | Acme         | We need a backend |
      | ruby-2      | Ruby Engineer     | Acme         | We need a backend |
      | python-1    | Python Developer  | Acme         | We need data work |
    And the vacancy search index is refreshed
    And the last User has the following SavedFilter records:
      | name    | include_tags | include_ops | exclude_tags |
      | Backend | ["ruby"]     | []          | []           |
      | Data    | ["python"]   | []          | []           |

  Scenario: Every preset shows how many vacancies match it now
    When I visit the Vacancy index page
    Then the preset "Backend" shows "2"
    And the preset "Data" shows "1"
