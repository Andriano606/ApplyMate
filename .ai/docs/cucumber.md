# Cucumber Feature Testing Guidelines

## Cucumber Feature Tests

### Feature File Organization

Feature files are organized by model/controller structure under `features/user_stories/`:

```
features/user_stories/{domain}/{model}/
├── index.feature       # List, search, filter
├── create.feature      # New and create actions
├── update.feature      # Edit and update actions
├── destroy.feature     # Delete/destroy actions
├── show.feature        # Show/detail page
├── {action}.feature    # Custom controller actions
└── {action}/           # Subdirectory for complex actions
    ├── main.feature
    └── variant.feature
```

**Examples:**
- `Sale::Customer` → `features/user_stories/sale/customer/*.feature`
- `Purchase::SupplierInvoice` → `features/user_stories/purchase/supplier_invoice/*.feature`
- `Salary::AMelding` → `features/user_stories/salary/a_melding/*.feature`

**File naming:**
| File | Content |
| -- | -- |
| `index.feature` | Index page, listing, search, filtering |
| `create.feature` | New and create actions |
| `update.feature` | Edit and update actions |
| `destroy.feature` | Delete actions |
| `{action}.feature` | Custom actions (e.g., `preview.feature`, `approve.feature`, `cancel.feature`) |

**For many tests on one action**, split into subdirectories:
```
features/user_stories/purchase/supplier_invoice/index/
├── main.feature
├── amounts.feature
└── filtering.feature
```

See [features/README.md](../../features/README.md) for complete documentation on feature file organization and step definitions.

### Step Definition Organization

Step definitions are organized in `features/steps/` to mirror the `user_stories/` structure:

```
features/steps/
├── generic/              # Shared steps - use these first
│   ├── given.rb
│   ├── when.rb
│   └── then.rb
├── session/
│   └── given.rb          # Authentication steps
├── {domain}/
│   └── {model}/
│       ├── given.rb
│       ├── when.rb
│       └── then.rb
└── ...
```

**File naming:**
- `given.rb` - Given step definitions
- `when.rb` - When step definitions
- `then.rb` - Then step definitions
- `methods.rb` - Shared helper methods (optional)

### Other Guidelines

- Follow the Given-When-Then pattern for scenario steps
- **Adding new step definitions should be an absolute last resort** - search thoroughly first:
  1. Generic steps in `steps/generic/`
  2. Area-specific steps in `steps/{domain}/{area}/`
- Place new step definitions in `/features/steps/{domain}/{area}` directory with standardized file names (`given.rb`, `when.rb`, `then.rb`)
- Use Ukrainian text directly in feature files (default locale is `uk`)

## Step Definition Pattern: wait_for for First Database Assertions

**ALWAYS use `wait_for` for the FIRST database assertion in cucumber step definitions:**

- **Problem**: Browser form submissions may not complete their database operations immediately, causing timing issues in cucumber tests
- **Solution**: Use `wait_for` (from rspec-wait gem) for the first database query in each step definition
- **Pattern**: Only the first assertion needs `wait_for` - subsequent assertions in the same step can use direct `expect`

**Examples:**
```ruby
# Good - First assertion uses wait_for, subsequent use expect
Then(/^The payslip to (.*) should have line items:$/) do |employee_name, table|
  wait_for { Salary::Employee.find_by(full_name: employee_name).payslips.last }.to be_present  # FIRST
  payslip = Salary::Employee.find_by(full_name: employee_name).payslips.last
  expect(payslip.salary_payslip_line_items.count).to eq table.hashes.count  # SUBSEQUENT
end

# Bad - Direct expect for first database assertion (timing issues)
Then(/^The supplier invoice's name should be "(.*)"$/) do |name|
  expect(@supplier_invoice.reload.supplier.name).to eq(name)  # Could fail due to timing
end

# Good - First assertion uses wait_for
Then(/^The supplier invoice's name should be "(.*)"$/) do |name|
  wait_for { @supplier_invoice.reload.supplier.name }.to eq(name)  # Handles timing issues
end

# Good - Use wait_until_not_nil helper for records that should exist
Then(/^The bank reconciliation should have values:$/) do |table|
  bank_account = Bank::Account.find_by(name: bank_name)
  bank_reconciliation = wait_until_not_nil { BankReconciliation.find_by(bank_account:, beginning_on: date) }
  expect(bank_reconciliation.incoming_amount_cents).to eq expected_value
end
```

**Apply wait_for to these first assertion patterns (always include the assertion):**
- `expect(@model.reload.property).to eq(value)` → `wait_for { @model.reload.property }.to eq(value)`
- `expect(Model.find_by(...)).to be_present` → `wait_for { Model.find_by(...) }.to be_present`
- `expect(Model.last.property).to eq(value)` → `wait_for { Model.last.property }.to eq(value)`
- `expect(@model.association.property).to eq(value)` → `wait_for { @model.reload.association.property }.to eq(value)` (**Important: Always include `.reload` for instance variables!**)
- `expect(@model.association.count).to eq(3)` → `wait_for { @model.association.count }.to eq(3)` (**Exception: `.count` always hits DB, no `.reload` needed**)
- `expect(@model.association.size).to eq(3)` → `wait_for { @model.association.count }.to eq(3)` (**Use `.count` instead of `.size` for fresh data**)

**Prefer concise patterns and helper methods:**
- `wait_for { Model.find_by(code:)&.property }.to eq(value)` (**Good: concise single expression**)
- `wait_until_not_nil { Model.find_by(code:) }` (**Preferred: for records that should exist**)
- Instead of verbose: `model = nil; wait_for { model = Model.find_by(code:) }.to be_present; model = Model.find_by(code:)`

**Prefer direct wait_for assertions when accessing single properties:**
- `wait_for { Model.last.property }.to eq(expected_value)` (**Best: waits for specific property**)
- Instead of: `model = wait_until_not_nil { Model.last }; expect(model.property).to eq(expected_value)` (**Less optimal: waits for record, then separate assertion**)

**Use `wait_until_not_nil` helper when:**
1. **Multiple properties need to be accessed** from the same record
2. **UI interactions** require the record object (e.g., `find()`, `within()` blocks)
3. **Complex logic** needs to be performed with the record

**Examples:**

```ruby
# Good - Direct wait_for for single property
wait_for { Journal.last.number_year }.to eq Date.current.year

# Good - wait_until_not_nil for multiple properties or UI interactions
journal = wait_until_not_nil { Journal.last }
expect(journal.number_year).to eq Date.current.year
expect(journal.status).to eq 'active'
within("[data-model-hashid='#{journal.hashid}']") do
  # UI interactions
end

# Good - wait_until_not_nil when record used multiple times
company = wait_until_not_nil { Company.find_by(name: company_name) }
expect(company.name).to eq expected_name
expect(company.active).to be true
```

**Important: `wait_for` requires an assertion** - just `wait_for { Model.find_by(...) }` without `.to be_present` or similar matcher does nothing useful!