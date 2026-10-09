# frozen_string_literal: true

# The Ashby application form schema without a browser (design §5.3, §18 item 6): the public, undocumented
# `POST <origin>/api/non-user-graphql?op=ApiJobPosting` the job board SPA itself calls (the query is the SPA's,
# api_job_posting.graphql). One GuardedFetch (address checked and pinned, no redirects, curl --max-time). Read-only.
#
# model = [Apply::Field] (source schema_api, id "ashby:<field path>", semantic and target nil: the Classifier and
# DiscoverFields fill them), one per visible field entry, each path once. A failed request (curl error / timeout),
# non-2xx, unparsable JSON, GraphQL errors, no posting or no form -> Apply::Platform::SchemaUnavailable (the adapter
# traces it and the engine reads the DOM). An unknown field type maps to 'text'; DOM discovery reconciles it.
#
# Kinds: ValueSelect renders as a combobox above COMBOBOX_MIN_OPTIONS options and as radios otherwise
# (research/live_probe.md); Boolean is a Yes/No radio group.
class Apply::Operation::Platform::Ashby::FetchSchema < ApplyMate::Operation::Base
  QUERY = Rails.root.join('app/concepts/apply/operation/platform/ashby/api_job_posting.graphql').read.freeze
  COMBOBOX_MIN_OPTIONS = 6
  KINDS = {
    'String' => 'text', 'Email' => 'email', 'Phone' => 'tel', 'File' => 'file', 'Number' => 'number',
    'LongText' => 'textarea', 'MultiValueSelect' => 'checkbox_group', 'Boolean' => 'radio_group', 'Date' => 'date',
    'Location' => 'autocomplete'
  }.freeze
  BOOLEAN_OPTIONS = [ { 'label' => 'Yes', 'value' => 'true' }, { 'label' => 'No', 'value' => 'false' } ].freeze

  def perform!(slug:, jid:, http:, origin:, **)
    skip_authorize
    response = ApplyMate::Net::Operation::GuardedFetch.call(
      url: "#{origin}/api/non-user-graphql?op=ApiJobPosting", http:, method: :post,
      body: request_body(slug, jid), headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
    ).model
    self.model = fields(entries(parse!(response)))
  rescue ApplyMate::Client::ImpersonateHttp::RequestError => e
    unavailable!("request failed: #{e.message.truncate(120)}")
  end

  private

  def request_body(slug, jid)
    { operationName: 'ApiJobPosting',
      variables: { organizationHostedJobsPageName: slug, jobPostingId: jid },
      query: QUERY }.to_json
  end

  def parse!(response)
    unavailable!("HTTP #{response.status}") unless response.status.to_i.between?(200, 299)
    json = JSON.parse(response.body.to_s)
    unavailable!("errors: #{Array(json['errors']).pluck('message').join('; ').truncate(200)}") if json['errors'].present?
    json.dig('data', 'jobPosting', 'applicationForm') || unavailable!('no applicationForm')
  rescue JSON::ParserError => e
    unavailable!("invalid JSON: #{e.message.truncate(120)}")
  end

  def entries(form)
    visible = Array(form['sections']).reject { |section| section['isHidden'] }
                                     .flat_map { |section| Array(section['fieldEntries']) }
                                     .reject { |entry| entry['isHidden'] || entry.dig('field', 'isDeactivated') }
    found = visible.select { |entry| entry.dig('field', 'path').present? }.uniq { |entry| entry.dig('field', 'path') }
    found.presence || unavailable!('form has no field entries')
  end

  def fields(entries)
    built = entries.map { |entry| field(entry) }
    ordinals = Hash.new(0)
    built.map do |field|
      ordinal = ordinals[field.signature]
      ordinals[field.signature] += 1
      field.with(ordinal:)
    end
  end

  def field(entry)
    raw = entry.fetch('field')
    options = options_of(raw)
    kind = kind_of(raw.fetch('type'), options)
    label = raw['title'].to_s.squish.presence
    Apply::Field.new(
      id: "#{Apply::Platform::Ashby.key}:#{raw.fetch('path')}", kind:, label:,
      description: text_of(entry['descriptionHtml']), placeholder: nil, required: entry['isRequired'] == true,
      multiple: raw['type'] == 'MultiValueSelect', max_length: nil, accept: nil, autocomplete: nil, options:, semantic: nil,
      widget: nil, target: nil, signature: Apply::Field.signature_for(label:, kind:, option_labels: options&.pluck('label')),
      ordinal: 0, default_value: nil, condition: nil, source: 'schema_api', page: nil
    )
  end

  def kind_of(type, options)
    return options.to_a.size >= COMBOBOX_MIN_OPTIONS ? 'combobox' : 'radio_group' if type == 'ValueSelect'

    KINDS.fetch(type, 'text')
  end

  def options_of(raw)
    return BOOLEAN_OPTIONS if raw['type'] == 'Boolean'

    values = raw['selectableValues']
    values&.map { |value| { 'label' => value['label'].to_s.squish, 'value' => (value['value'] || value['label']).to_s } }
  end

  def text_of(html)
    return if html.blank?

    Nokogiri::HTML.fragment(html).text.squish.presence
  end

  def unavailable!(reason)
    raise Apply::Platform::SchemaUnavailable, "ashby ApiJobPosting: #{reason}"
  end
end
