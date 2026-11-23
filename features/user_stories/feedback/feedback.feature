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
    When I pick the rating 8
    And I fill in "Ваш відгук" with "Handy vacancy bank"
    And I click on "Опублікувати"
    Then I see notice "Дякуємо! Ваш відгук опубліковано"
    And my own feedback shows "Handy vacancy bank"
    And I see 3 feedback cards
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
    When I pick the rating 9
    And I fill in "Ваш відгук" with "Got much better"
    And I click on "Зберегти"
    Then I see notice "Відгук оновлено"
    And my own feedback shows "Got much better"
    And I see 3 feedback cards
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

  Scenario: An admin replies under a user's review
    Given the OAuth user is "Admin" with email "admin@example.com"
    And I am logged in as Andrii Kuluev
    And the last User has:
      | admin | true |
    When I visit the Feedback index page
    And I start a reply under the review by "Olena"
    And I fill in the reply with "Thanks, we are on it"
    And I send the reply
    Then I see notice "Відповідь опубліковано"
    And the thread under the review by "Olena" shows "Thanks, we are on it"
    And the thread under the review by "Olena" shows "Адмін"

  Scenario: The author answers in their own thread
    Given the OAuth user is "Petro" with email "petro@example.com"
    And I am logged in as Andrii Kuluev
    And the last User has the following Feedback records:
      | rating | body            | posted_via |
      | 6      | Could be better | web        |
    And an admin "Support" has replied "What exactly is missing?" under the review by "Petro"
    When I visit the Feedback index page
    Then the thread under the review by "Petro" shows "What exactly is missing?"
    When I start a reply under the review by "Petro"
    And I fill in the reply with "More job boards please"
    And I send the reply
    And the thread under the review by "Petro" shows "More job boards please"
    And the thread under the review by "Petro" shows "Автор"

  Scenario: A third user sees the thread but cannot reply
    Given an admin "Support" has replied "Thanks for the feedback" under the review by "Olena"
    And the OAuth user is "Stranger" with email "stranger@example.com"
    And I am logged in as Andrii Kuluev
    When I visit the Feedback index page
    Then the thread under the review by "Olena" shows "Thanks for the feedback"
    And there is no reply form on the page

  Scenario: An unread admin reply is flagged in the navbar and highlighted once
    Given the OAuth user is "Petro" with email "petro@example.com"
    And I am logged in as Andrii Kuluev
    And the last User has the following Feedback records:
      | rating | body            | posted_via |
      | 6      | Could be better | web        |
    And an admin "Support" has replied "What exactly is missing?" under the review by "Petro"
    When I visit the home page
    Then the navbar shows the unread feedback reply badge
    When I click on "Відгуки"
    Then the thread under the review by "Petro" shows "What exactly is missing?"
    And the reply "What exactly is missing?" is marked as new
    When I visit the home page
    Then the navbar shows no unread feedback reply badge
    When I visit the Feedback index page
    Then the thread under the review by "Petro" shows "What exactly is missing?"
    And the reply "What exactly is missing?" is not marked as new
