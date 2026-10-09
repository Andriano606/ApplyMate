# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::InputRequest, type: :component do
  let(:user)       { create(:user) }
  let(:expires_at) { 10.minutes.from_now.change(usec: 0) }
  let(:request)    { { 'kind' => 'email_code', 'requested_at' => Time.current.iso8601, 'expires_at' => expires_at.iso8601 } }
  let(:apply)      { create(:apply, :running, user:, stage: 'awaiting_input', input_request: request) }

  def html(apply, **options)
    render_inline(described_class.new(apply:, **options))
    page.native
  end

  it 'renders the code form with the title, hint and expiry' do
    node = html(apply, user:)

    expect(node.text).to include(I18n.t('apply.input_request.email_code.title'), I18n.t('apply.input_request.email_code.hint'))
    expect(node.text).to include(I18n.t('apply.input_request.expires_at', time: I18n.l(expires_at, format: :short)))
    expect(node.text).not_to include('translation missing')
    expect(node.text).to include(I18n.t('apply.input_request.submit'))
  end

  it 'posts the code to provide_input as turbo_stream' do
    form = html(apply, user:).at_css('form')
    input = form.at_css('input[name=code]')

    expect(form['method']).to eq('post')
    expect(form['action']).to eq("/applies/#{apply.hashid}/provide_input.turbo_stream")
    expect(form['data-controller']).to eq('turbo-form')
    expect(input['autocomplete']).to eq('one-time-code')
    expect(input['inputmode']).to eq('numeric')
    expect(input['maxlength']).to eq('32')
  end

  it 'uses the generic texts for another kind' do
    apply.input_request = request.merge('kind' => 'sms_code')

    expect(html(apply, user:).text).to include(I18n.t('apply.input_request.generic.title'), I18n.t('apply.input_request.generic.hint'))
  end

  it 'renders with the default user too (current_user context)' do
    expect(html(apply).at_css('input[name=code]')).to be_present
  end

  describe 'render?' do
    it 'is empty once the code was provided' do
      apply.input_response = { 'code' => '123456', 'at' => Time.current.iso8601 }

      expect(html(apply, user:).text).to be_blank
    end

    it 'is empty in another stage' do
      apply.stage = 'fill'

      expect(html(apply, user:).text).to be_blank
    end

    it 'is empty without an input request' do
      apply.input_request = nil

      expect(html(apply, user:).text).to be_blank
    end

    it 'is empty for a non-running state' do
      apply.state = :failed

      expect(html(apply, user:).text).to be_blank
    end
  end
end
