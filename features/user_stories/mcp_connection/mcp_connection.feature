Feature: Connect Claude (MCP)
  A signed-in user opens a modal from the user menu, copies a ready
  `claude mcp add` command with their personal token and can regenerate the
  token. Opening the modal never creates a token.

  Background:
    Given I am logged in as Andrii Kuluev
    And I visit the home page

  Scenario: Opening the modal does not create a token
    When I pick Connect Claude in the user menu
    Then I should see the modal
    And I see text "Підключити Claude (MCP)"
    And the MCP token status says no token was created
    And the MCP command has a placeholder instead of a token
    And I do not see button "Перегенерувати токен"
    And no personal MCP token exists

  Scenario: Copying the command creates the personal token and shows it
    When I pick Connect Claude in the user menu
    And I click on "Скопіювати команду"
    Then the MCP command contains the personal token of the last User
    And the MCP token status says a token exists
    And I see button "Перегенерувати токен"
    And the last User has 1 personal MCP token

  Scenario: Regenerating the token replaces it after a confirmation
    When I pick Connect Claude in the user menu
    And I click on "Скопіювати команду"
    Then the MCP command contains the personal token of the last User
    When I remember the MCP token
    And I regenerate the MCP token and confirm
    Then I see notice "Новий токен створено"
    And the MCP command contains the personal token of the last User
    And the MCP command no longer contains the earlier token
    And the last User has 1 personal MCP token
