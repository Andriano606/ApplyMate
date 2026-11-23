Feature: Guest banner on the home page
  Visitors who are not signed in see, above the search, what ApplyMate is in a
  few plain words and a button to sign in with Google to connect Claude (MCP).

  Background:
    Given the OAuth user is "Andrii" with email "andrii@example.com"
    And a job source exists

  Scenario: A guest sees what the service is and how to get MCP
    When I visit the home page
    Then I see text "Усі IT-вакансії в одному місці"
    And I see text "Підключіть Claude"
    And I see button "Увійти через Google"

  Scenario: A signed-in user does not see the banner
    Given I am logged in as Andrii Kuluev
    When I visit the home page
    Then I do not see text "Усі IT-вакансії в одному місці"
