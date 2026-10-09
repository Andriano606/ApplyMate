# frozen_string_literal: true

# Apply::Platform::Ashby pointed at FixtureSite's alt origin (`/ashby`): the canonical form URL
# (`<alt>/ashby/<slug>/<jid>/application`, served as ashby/application.html), the schema read
# (`<alt>/ashby/api/non-user-graphql`) and the signals (job URL / frame src `<alt>/ashby/<slug>/<jid>`, the embed
# script, ?ashby_jid=, the field-entry DOM marker) all derive from `origin`, the one seam the production adapter has
# for this. The key stays `ashby`: schema field ids ("ashby:<path>") and Context#schema_keys depend on it.
#
# FixtureSite picks its ports when it starts, after this file is loaded, so the signals are declared on first use
# instead of in the class body. A spec that runs the real detection puts the class into the registry:
#
#   stub_fixture_ashby_registry   # Registry.platforms / dom_markers / known_hosts / fingerprint -> FixtureAshby
class FixtureAshby < Apply::Platform::Ashby
  JID = '20587adf-cf02-473e-8a80-7b009711a2cf'
  SLUG = 'preply'

  class << self
    def origin
      raise 'FixtureAshby needs FixtureSite (a :browser example)' unless FixtureSite.alt_port

      FixtureSite.alt_url('/ashby')
    end

    def key
      'ashby'
    end

    def signals
      return @signals if @signals

      @signals = []
      declare_signals!
      @signals
    end

    def canonical_form_url(slug: SLUG, jid: JID)
      "#{origin}/#{slug}/#{jid}/application"
    end
  end
end

# Canned AI answers for the fixture posting (spec/fixtures/files/apply_engine/ashby/api_job_posting.json): every
# non-file field the AI may be asked about, with a confidence above every review threshold. Fields the facts or the
# consent policy answer first ignore their entry here (Answer::Resolve reads only the fields it asked about).
module FixtureAshbyAnswers
  def self.field_answers(email:, phone:)
    {
      '_systemfield_name' => 'Jane Doe',
      '_systemfield_email' => email,
      '6257e5b0-1d2a-4c55-9a51-3f0f2a6c1e01' => phone,
      'd1689d85-6c1f-4b8e-9b0a-2c7e5d1f3a02' => 'https://www.linkedin.com/in/janedoe',
      '3086edf6-0b7d-4a3c-8e2f-9d4c1b5a6e03' => nil,
      '9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04' => 'LinkedIn',
      '677edf26-2a4b-4c8d-9e1f-3b5c7d9e1f05' => nil,
      'ab315a8b-7c2d-4e9f-8a1b-5c6d7e8f9a06' => '3-5 years',
      '0b9874a9-3d4e-4f5a-9b6c-7d8e9f0a1b07' => 12,
      '596274cb-4e5f-4a6b-8c7d-9e0f1a2b3c08' => '3500',
      '8f841092-5f6a-4b7c-9d8e-0f1a2b3c4d09' => 'I enjoy helping people learn languages.',
      'c1d2e3f4-6a7b-4c8d-9e0f-1a2b3c4d5e10' => 'Yes',
      'c408722a-7b8c-4d9e-8f0a-2b3c4d5e6f11' => [ 'Acknowledge/Confirm' ],
      'e5f6a7b8-8c9d-4e0f-9a1b-3c4d5e6f7a12' => nil
    }
  end

  def fixture_ashby_answers_json(email: unique_email, phone: unique_phone)
    answers = FixtureAshbyAnswers.field_answers(email:, phone:).to_h { |path, value| [ "ashby:#{path}", { value:, confidence: 0.95 } ] }
    "```json\n#{JSON.generate(answers)}\n```"
  end

  # Registry lookups are memoized from the production PLATFORMS: point every one of them at FixtureAshby.
  def stub_fixture_ashby_registry
    registry = Apply::Platform::Registry
    allow(registry).to receive_messages(
      platforms: [ FixtureAshby ],
      dom_markers: FixtureAshby.signals.select { |signal| signal.kind == :dom }.map(&:pattern),
      known_hosts: FixtureAshby.signals.select { |signal| signal.kind == :host }.map(&:pattern),
      fingerprint: registry.fingerprint_of([ FixtureAshby ])
    )
  end
end

RSpec.configure { |config| config.include FixtureAshbyAnswers }
