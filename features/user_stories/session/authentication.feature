# frozen_string_literal: true

Feature: Google authentication
  As a user
  I want to sign in with Google
  So that I can access the application

  Scenario: User signs in with Google
    Given the OAuth user is "Test User" with email "test@example.com"
    When I open the home page
    And I click on "Увійти"
    And I click on "Увійти через Google"
    Then I see notice "Ви успішно увійшли"

  Scenario: User signs out
    Given the OAuth user is "Test User" with email "test@example.com"
    When I open the home page
    And I click on "Увійти"
    And I click on "Увійти через Google"
    Then I see notice "Ви успішно увійшли"
    When I click on "Вийти"
    Then I see notice "Ви вийшли з системи"
    And I see link "Увійти"
