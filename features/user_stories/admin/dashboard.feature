# frozen_string_literal: true

Feature: Admin dashboard
  As an admin
  I want to access the admin dashboard
  So that I can manage materials

  Scenario: Admin user sees dashboard with navigation links
    Given the OAuth user is "Admin User" with email "admin@example.com"
    When I open the home page
    And I click on "Увійти"
    And I click on "Увійти через Google"
    Then I see notice "Ви успішно увійшли"
    Given the User with email "admin@example.com" has:
      | admin | true |
    When I visit the admin dashboard
    Then I see text "Панель адміністратора"
    And I see link "Користувачі"
