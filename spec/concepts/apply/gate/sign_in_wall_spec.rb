# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::SignInWall do
  let(:ctx) { engine_context(create(:apply)) }
  let(:form_url) { 'https://jobs.example.com/apply' }

  def check(event: :http_resolved, snapshot: nil, **evidence)
    described_class.new.call(ctx, event:, snapshot:,
                                  evidence: Apply::Operation::Engine::Detect::Evidence.build(**evidence))
  end

  def snapshot(password_fields)
    ApplyMate::Client::Browser::Snapshot.new(
      frames: [ { 'ref' => 'f0', 'url' => form_url, 'captcha' => [], 'password_fields' => password_fields } ],
      elements: [], evidence: { frame_urls: [ form_url ], script_srcs: [], iframe_srcs: [], dom_markers: {} },
      digest: ''
    )
  end

  [
    'https://accounts.google.com/v3/signin/identifier',
    'https://login.microsoftonline.com/common/oauth2/authorize',
    'https://www.linkedin.com/oauth/v2/authorization',
    'https://github.com/login?return_to=x'
  ].each do |url|
    it "stops on the sign-in page #{url}" do
      expect { check(current_urls: [ url ]) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt.code).to eq(:login_required)
      }
    end
  end

  it 'stops on a rendered page with a visible password field' do
    expect { check(event: :after_action, current_urls: [ form_url ], snapshot: snapshot(1)) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.detail).to eq('password field') }
  end

  it 'passes an ordinary form and other LinkedIn / GitHub pages' do
    expect(check(event: :after_goto, current_urls: [ form_url ], snapshot: snapshot(0))).to be_nil
    expect(check(current_urls: [ 'https://www.linkedin.com/jobs/view/1', 'https://github.com/acme/jobs' ])).to be_nil
  end
end
