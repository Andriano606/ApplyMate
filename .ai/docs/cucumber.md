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
Given the last Apply record has:
  | status | completed |

# Update by attribute value
Given the Vacancy with title "Rails Developer" has:
  | company_name | New Corp |
```

### Create child records on the last parent

```gherkin
Given the last User has the following SourceProfile records:
  | name    | source_id |
  | My Profile | 1      |
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
When I visit the SourceProfile index page
When I visit the new SourceProfile page
When I visit the edit SourceProfile page            # uses SourceProfile.last
When I visit the SourceProfile index page with source_id 5
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
When I attach the file "resume.pdf" to "CV"    # from spec/fixtures/files/
```

### Buttons and links

```gherkin
When I click on "Submit"         # works for both links and buttons, uses JS click
When I click the edit button for "Acme Corp" in the table
When I click the delete button for "Acme Corp" in the table   # confirms dialog
When I hover over "Backend"      # dwells past Turbo's 100ms hover-prefetch delay
```

`I click on` fires a JS click, which does **not** move the pointer — use `I hover over`
when a scenario needs the real hover behaviour (Turbo 8 prefetches links on hover).

## Then Steps

### Text and flash messages

```gherkin
Then I see text "Welcome"
Then I do not see text "Error"
Then I see notice "Record saved"       # checks [data-flash-target="message"]
Then I see alert "Invalid input"
```

### Saved filter pills

```gherkin
Then the preset "Backend" shows "+1"      # scoped to that pill only
Then the preset "Backend" shows no deltas # no +appeared / −disappeared badge
```

A **positive** assertion is satisfied by the pre-click DOM, so after `I click on` assert
the badge that has to *disappear* first — that one waits for the response to land.

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
Then the last Apply record should have:
  | status | completed |

Then the Apply with status "pending" record should have:
  | status | completed |

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
wait_for { Apply.last&.status }.to eq("completed")
```

`Capybara.default_max_wait_time` is set to **30 seconds** in `features/support/jobs.rb`.
