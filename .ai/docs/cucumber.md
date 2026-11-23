# Cucumber / Feature Tests

Feature files live in `features/user_stories/`. Steps are in `features/steps/`, split the
same way as `app/concepts/`:

- `generic/{given,when,then}.rb` — steps that work for any model or page (`I click on`,
  `the following {word} records:`, `I hover over`).
- `<resource>/{given,when,then}.rb` — steps that belong to one domain: `source/given.rb`,
  `vacancy/given.rb`, `saved_filter/then.rb`.

A step that names a model belongs in that resource's folder, not in `generic/`. Everything
under `features/` is auto-required, so a new folder or file needs no wiring.

## Given Steps

### Seed records from a table

```gherkin
Given the following Vacancy records:
  | title           | company_name |
  | Rails Developer | Acme Corp    |
```

Values are auto-coerced: integers (`42`), floats (`3.14`), booleans (`true`/`false`), JSON arrays/objects. Uses `find_or_create_by!`.

### Update an existing record

```gherkin
# Update the last record of that model
Given the last SavedFilter record has:
  | name | Backend |

# Update by attribute value
Given the Vacancy with title "Rails Developer" has:
  | company_name | New Corp |
```

### Create child records on the last parent

```gherkin
Given the last User has the following SavedFilter records:
  | name    |
  | Backend |
```

### OAuth / session setup

```gherkin
Given the OAuth user is "Test User" with email "test@example.com"
Given I am logged in as Andrii Kuluev
```

### Records the table step cannot build

`Given the following {word} records:` uses `find_or_create_by!`, so it cannot satisfy
models that validate an attachment. FactoryBot is available in steps
(`features/support/factory_bot.rb`), and `Source` has its own step because of the
required logo:

```gherkin
Given a job source exists
Given the last Source has the following Vacancy records:
  | external_id | title          | company_name | description |
  | ruby-1      | Ruby Developer | Acme         | Backend role |
```

### Make indexed vacancies searchable

Elasticsearch callbacks fire in Cucumber, but a document is only searchable after a
refresh, and the default interval (1s) is too slow to rely on mid-scenario:

```gherkin
Given the vacancy search index is refreshed
```

## When Steps

### Navigate to a page

```gherkin
When I visit the home page
When I open the admin dashboard
When I visit the Vacancy index page
When I visit the show Vacancy page                  # uses @vacancy or Vacancy.last
When I visit the Vacancy index page with source_id 5   # "with <param> <value>" adds a query param
```

The step infers the route using `polymorphic_path`. Namespace prefix `admin` routes to `admin_*_path`.

### Form interactions

```gherkin
When I fill in "Name" with "Acme"           # plain fill_in
When I fill in "Search" with "rails"        # if field has data-action="turbo-form#update",
                                            # types char-by-char and waits for Turbo response
When I check "Active"
When I choose "Option A"
When I select "Value" from "Dropdown"
When I set field "vacancy[title]" to "Rails"   # by name attribute
When I attach the file "photo.jpg" to "Logo"    # from spec/fixtures/files/
```

### Buttons and links

```gherkin
When I click on "Submit"         # works for both links and buttons, uses JS click
When I click the edit button for "Acme Corp" in the table
When I click the delete button for "Acme Corp" in the table   # confirms dialog
```

`I click on` fires a JS click, which does **not** move the pointer.

### Vacancy cards

```gherkin
When I click "Приховати" on the vacancy card "Ruby Developer"   # scoped to that card; JS click, works on hover-only buttons
When I hover over the vacancy card "Ruby Developer"
```

### Hover-only UI

Headless Chrome has no pointing device and reports `(hover: none)`, while Tailwind v4
wraps every `hover:` / `group-hover:` rule in `@media (hover: hover)`. The driver in
`features/support/env.rb` therefore declares a mouse via `--blink-settings`, so
`I hover over ...` really reveals hover-only elements and `I do not see button` holds
before the hover (Selenium treats `opacity: 0` as not visible).

## Then Steps

### Text and flash messages

```gherkin
Then I see text "Welcome"
Then I do not see text "Error"
Then I see notice "Record saved"       # checks [data-flash-target="message"]
Then I see alert "Invalid input"
```

### Vacancy cards

```gherkin
Then the vacancy card "Ruby Developer" is hidden       # [data-hidden="true"] on the card
Then the vacancy card "Ruby Developer" is not hidden
Then I do not see button "Повернути"                    # visibility-aware: opacity 0 counts as not visible
```

### Vacancy page

```gherkin
When I click on "Description" in the vacancy page navigation   # scoped to the vacancy page nav (I18n vacancy.show.nav.title)
Then the vacancy description renders 3 bullet points
Then the vacancy description renders "Requirements" in bold
Then the vacancy description contains no "script" element
```

### Saved filter pills

```gherkin
Then the preset "Backend" shows "2"       # scoped to that pill only (name + current count)
```

### Modal

```gherkin
Then I should see the modal
Then I should not see the modal
```

Checks for `[data-controller="turbo-modal"]`.

### Form validation errors

```gherkin
Then I see error "can't be blank" under "vacancy[title]"
```

### Database assertions (async-safe)

```gherkin
Then the last SavedFilter record should have:
  | name | Backend |

Then the SavedFilter with name "Backend" record should have:
  | name | Backend |

Then the following Vacancy records should exist:
  | title           | company_name |
  | Rails Developer | Acme Corp    |
```

These use `rspec/wait` (`wait_for`) so they poll until the DB matches (useful after background jobs).

### Table assertions

```gherkin
Then I should see the table:
  | Name            | Company  |
  | Rails Developer | Acme Corp |
```

Asserts both header names (in order) and row content (in order).

### Form values

```gherkin
Then I should see the form with values:
  | vacancy[title] | Rails Developer |
```

## Support: Background Jobs

Defined in `features/support/jobs.rb`. Jobs run **immediately** (synchronous) in Cucumber tests:

```ruby
ActiveJob::Base.queue_adapter.immediate = true
```

No need to manually drain queues in steps.

## Support: Elasticsearch

Defined in `features/support/elasticsearch.rb`. The index is recreated once per suite (`BeforeAll`/`AfterAll`). Before each scenario, all documents are wiped via `delete_by_query` with `refresh: true`.

Documents indexed via `after_commit` callbacks **do** fire in Cucumber (no transaction wrapping by default), so Elasticsearch callbacks work automatically in feature tests.

## Waiting for Async

`rspec/wait` is included globally via `features/support/wait_for.rb`. Use it in custom steps:

```ruby
wait_for { SavedFilter.last&.name }.to eq("Backend")
```

`Capybara.default_max_wait_time` is set to **30 seconds** in `features/support/jobs.rb`.
