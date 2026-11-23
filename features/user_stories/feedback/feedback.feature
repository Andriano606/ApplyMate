Feature: Feedback page
  Everyone can read the reviews of ApplyMate. Signed-in users publish one review
  of their own (rating 1-10 and a text) and can edit it later.

  Background:
    Given "Olena" has left a 9/10 feedback "Saves me hours every week"
    And "Taras" has left a 5/10 feedback "Fine but average"
    And "Ihor" has left a 2/10 feedback "Too many stale vacancies"

  Scenario: A guest reads the reviews and is invited to sign in
    When I visit the Feedback index page
    Then I see 3 feedback cards
    And I see text "Saves me hours every week"
    And I see text "Відгуки можуть залишати лише користувачі, що увійшли."
    And I see link "Увійти"

  Scenario: A signed-in user posts a review through the modal
    Given I am logged in as Andrii Kuluev
    When I visit the Feedback index page
    And I click on "Залишити відгук"
    Then I should see the modal
    When I select "8 — позитивно" from "Оцінка від 1 до 10"
    And I fill in "Ваш відгук" with "Handy vacancy bank"
    And I click on "Опублікувати"
    Then I see notice "Дякуємо! Ваш відгук опубліковано"
    And my own feedback shows "Handy vacancy bank"
    And I see 4 feedback cards
    And the last Feedback record should have:
      | rating     | 8   |
      | posted_via | web |

  Scenario: A user edits their review
    Given I am logged in as Andrii Kuluev
    And the last User has the following Feedback records:
      | rating | body      | posted_via |
      | 4      | Not great | web        |
    When I visit the Feedback index page
    And I click on "Редагувати"
    Then I should see the modal
    When I select "9 — позитивно" from "Оцінка від 1 до 10"
    And I fill in "Ваш відгук" with "Got much better"
    And I click on "Зберегти"
    Then I see notice "Відгук оновлено"
    And my own feedback shows "Got much better"
    And I see 4 feedback cards
    And the last Feedback record should have:
      | rating | 9 |

  Scenario: The reviews can be filtered by sentiment
    When I visit the Feedback index page
    And I filter the feedback by positive
    Then I see 1 feedback card
    And I see text "Saves me hours every week"
    And I do not see text "Fine but average"
    When I filter the feedback by negative
    Then I see 1 feedback card
    And I see text "Too many stale vacancies"
    When I filter the feedback by neutral
    Then I see 1 feedback card
    And I see text "Fine but average"
    When I filter the feedback by all
    Then I see 3 feedback cards
