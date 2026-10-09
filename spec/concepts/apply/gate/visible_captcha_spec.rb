# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Gate::VisibleCaptcha do
  let(:ctx) { engine_context(create(:apply)) }

  def check(*kinds)
    snapshot = ApplyMate::Client::Browser::Snapshot.new(
      frames: [ { 'captcha' => [] }, { 'captcha' => kinds } ], elements: [],
      evidence: { frame_urls: [], script_srcs: [], iframe_srcs: [], dom_markers: {} }, digest: ''
    )
    described_class.new.call(ctx, event: :before_submit, snapshot:,
                                  evidence: Apply::Operation::Engine::Detect::Evidence.empty)
  end

  it 'runs before the submit claim and after actions' do
    expect(described_class.events).to contain_exactly(:before_submit, :after_action)
  end

  %w[recaptcha recaptcha_challenge hcaptcha turnstile].each do |kind|
    it "sends a visible #{kind} to the 'apply yourself' state" do
      expect { check(kind) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :manual_apply_required, detail: :captcha)
      }
    end
  end

  it 'ignores invisible and score-based captchas' do
    expect(check('recaptcha_invisible', 'hcaptcha_invisible', 'turnstile_invisible')).to be_nil
  end
end
