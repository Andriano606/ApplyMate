# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Redact do
  def redact(text, apply: nil)
    described_class.call(text:, apply:).model
  end

  it 'returns nil for nil' do
    expect(redact(nil)).to be_nil
  end

  it 'stringifies symbols' do
    expect(redact(:google_forms)).to eq('google_forms')
  end

  it 'drops Cookie, Set-Cookie and Authorization header lines' do
    text = "GET /apply\nCookie: sessionid=abc123\nset-cookie: csrftoken=zzz; Path=/\n" \
           "Authorization: Bearer secret-token\nAccept: text/html"

    expect(redact(text)).to eq("GET /apply\nAccept: text/html")
  end

  it 'masks csrfmiddlewaretoken, csrftoken, sessionid, token and code values' do
    text = 'csrfmiddlewaretoken=AAA&csrftoken=BBB; sessionid=CCC access_token=DDD?code=EEE end'

    expect(redact(text)).to eq('csrfmiddlewaretoken=[REDACTED]&csrftoken=[REDACTED]; sessionid=[REDACTED] ' \
                               'access_token=[REDACTED]?code=[REDACTED] end')
  end

  context 'with the apply' do
    let(:user_email) { unique_email('jane.doe') }
    let(:user) { create(:user, email: user_email) }
    let(:apply) { create(:apply, user:) }

    before { apply.source_profile.update!(session_id: 'sess-0123456789abcdef') }

    it "replaces the profile's session id and the user's email with fact placeholders" do
      text = "login as #{user_email} with sess-0123456789abcdef failed"

      expect(redact(text, apply:)).to eq('login as {{fact.email}} with {{fact.session_id}} failed')
    end
  end

  it 'replaces any other email address' do
    expect(redact("reply to #{unique_email('hr+jobs')} now")).to eq('reply to {{email}} now')
  end

  it 'replaces phone numbers in the international and the national format' do
    digits = unique_phone.delete_prefix('+380') # 9 random digits: operator code + subscriber number
    international = "+38 (0#{digits[0, 2]}) #{digits[2, 3]}-#{digits[5, 2]}-#{digits[7, 2]}"
    national = "0#{digits}"

    expect(redact("call #{international} or #{national}")).to eq('call {{phone}} or {{phone}}')
  end

  it 'leaves short numbers alone' do
    expect(redact('HTTP 422 on step 3')).to eq('HTTP 422 on step 3')
  end

  it 'truncates to MAX_LENGTH characters' do
    expect(redact('x' * 5_000).length).to eq(described_class::MAX_LENGTH)
  end

  it 'truncates to a given max_length' do
    expect(described_class.call(text: 'x' * 5_000, max_length: 3_000).model.length).to eq(3_000)
  end
end
