# RSpec Testing Guidelines

## Rules when creating tests

- Focus on testing behavior rather than Rails' built-in features
- Do not add association tests in RSpec
- Do not add validation tests in RSpec
- Do not add scope tests in RSpec
- Model specs should only test methods with more than 5 lines of code
- Do not create policy tests (e.g., no \*\_policy_spec.rb files)
- Do not create component/view tests (e.g., no component/\*\_spec.rb files)
- Do not wrap basic operation tests in a `describe '#perform!'` block - place them at the root level
- Try to avoid too much mocking in RSpec tests
- Use top-level namespace definition with `::` for clearer, more concise class definition of nested namespaces
- After writing tests, always run them with `bundle exec rspec path/to/spec.rb` to verify they pass
- Examine test failures carefully and fix both tests and implementation as needed
- Tests should never introduce warnings. If test output contains warnings, fix the underlying code.
- **Always use I18n for text content in tests** instead of hardcoded strings:
  - Good: `I18n.t('supplier_invoice.updated_and_finalized.notice', invoice_link: '').strip`
  - Bad: `'ble oppdatert og bilagsført'` or `'was updated and finalized'`
  - This ensures tests work across different locales and remain maintainable when translations change
- **Use seeded companies and users instead of creating new ones**:
  - Good: `let(:company) { companies.wideroe }` and `let(:user) { users.david }`
  - Bad: `let(:company) { create(:company) }` and `let(:user) { create(:user) }`
  - Seeded data is faster and provides consistent test fixtures
  - Available seeded companies: `companies.wideroe`, etc.
  - Available seeded users: `users.david`, etc.
- **Combine multiple assertions into a single test** instead of creating separate tests for each assertion:
  - Good: One test with multiple expectations that all verify the same operation result
  - Bad: Multiple separate tests that each call `result` and check only one thing
  - Example of good pattern:
    ```ruby
    it 'succeeds' do
      expect(result).to be_success
      expect(approval.reload.remote_status).to eq 'cancelled'
      expect(result[:notice][:text]).to eq(I18n.t('cancelled', scope: 'bank.psd2.ztl.approval.remote_status'))
    end
    ```
  - Example of bad pattern:
    ```ruby
    it 'succeeds' do
      expect(result).to be_success
    end

    it 'updates approval status to cancelled' do
      expect(result).to be_success
      approval.reload
      expect(approval.remote_status).to eq 'cancelled'
    end

    it 'shows notice with the cancelled status' do
      expect(result).to be_success
      expect(result[:notice][:text]).to eq(I18n.t('cancelled', scope: 'bank.psd2.ztl.approval.remote_status'))
    end
    ```
  - This reduces duplication, makes tests faster, and keeps related assertions together

## Common Commands

- Run tests: `bundle exec rspec spec/path/to/test_file_spec.rb`
- Run specific test: `bundle exec rspec spec/path/to/test_file_spec.rb:LINE_NUMBER`
- Generate factory: `bundle exec rails g factory_bot:model ModelName`

## Factorybot

- **Keep FactoryBot factories minimal - no association setups**:
  - Do NOT set up associations in factories (no `company { build :company }`, `user { build :user }`, etc.)
  - Do NOT use `after(:create)` callbacks or transient attributes
  - Factories should only contain the minimal attributes needed for the model to be valid
  - Good: Factory with only non-association attributes (strings, numbers, enums, etc.)
  - Bad: Factory with association setups like `belongs_to` or `has_many` relationships
  - All associations should be set up explicitly in the tests themselves when needed
- **Don't override factory attributes unless necessary**:
  - Factories set default values for attributes - only override them when testing specific behavior
  - Good: `create :bank_psd2_ztl_approval, company:, user_consent:, remote_status: 'started'`
  - Bad: `create :bank_psd2_ztl_approval, company:, user_consent:, user_ip: '127.0.0.1', user_agent: 'Mozilla/5.0', remote_key: 'some-id', remote_status: 'started'`
  - Only set attributes that are:
    - Required associations (like `company:`, `user_consent:`)
    - Specifically different from factory defaults for the test case (like `remote_status: 'started'` when testing started state)
  - Don't set attributes that the factory already generates (like `user_ip`, `user_agent`, `remote_key`, etc.)
  - Check the factory file to see what attributes are already set before overriding them
- **Always create separate factory files for each model and submodel**:
  - Each model should have its own factory file, even if it's a subclass
  - Good: `spec/factories/bank/remote_payment_factory.rb` and `spec/factories/bank/psd2/ztl/remote_payment_v2_factory.rb`
  - Bad: Combining multiple model factories in a single file
  - Factory file names should match the model name and namespace structure

## Webmock

- **When using stub_request (WebMock), keep it simple**:
  - Good: `stub_request(:get, "https://api.example.com/endpoint")` for exact URLs
  - Good: `stub_request(:get, /endpoint/)` for URLs with query parameters or dynamic parts
  - Bad: `stub_request(:get, "url").with(headers: {...})` - unnecessary header matching
  - Only specify headers, query parameters, or request body when they are essential to the test
  - WebMock will match the request regardless of headers unless explicitly specified
  - Use minimal regex patterns that match just the essential part of the URL
- **When testing multiple scenarios with different response bodies, use let variables for file names to avoid duplication**:
  - Create a default `let(:response_file)` at the top level for the most common response file
  - Override this let variable in specific contexts that need different response files
  - Do the `File.read` in the `before` block using the let variable
  - Good pattern:
    ```ruby
    # Default response file
    let(:approval_response_file) { 'spec/assets/default_response.json' }
    
    before do
      approval_response_json = File.read(Rails.root.join(approval_response_file))
      stub_request(:get, 'https://api.example.com/endpoint')
        .to_return(status: 200, body: approval_response_json, headers: { 'Content-Type' => 'application/json' })
    end
    
    context 'when API returns success' do
      let(:approval_response_file) { 'spec/assets/success_response.json' }
      # tests here will automatically use the overridden response file
    end
    ```
  - Bad pattern: Duplicating `stub_request` calls in every context with inline response bodies
  - This approach is cleaner than storing the full File.read in let variables and reduces duplication
