# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ProxyMateSetting::Operation::Update, type: :operation do
  let(:current_user) { create(:user, :admin) }
  let(:attrs)        { { url: 'https://pm.example.com', api_key: 'pm_AbCdEfGhIjKl' } }
  let(:params)       { ActionController::Parameters.new(proxy_mate_setting: attrs) }

  def run(user: current_user, params: self.params)
    described_class.call(params:, current_user: user)
  end

  it 'creates the singleton row, stores the key encrypted and flashes a notice' do
    result = run

    expect(result).to be_success
    expect(result[:pundit]).to be true
    expect(result.message).to eq(I18n.t('admin.proxy_mate_setting.update.success'))
    setting = ProxyMateSetting.sole
    expect(setting.url).to eq('https://pm.example.com')
    expect(setting.api_key).to eq('pm_AbCdEfGhIjKl')
    expect(setting.api_key_preview).to eq('pm_AbCdEf…')
    expect(ProxyMateSetting.connection.select_value('SELECT api_key FROM proxy_mate_settings')).not_to include('pm_AbCdEf')
  end

  it 'keeps the stored key when the key field is blank' do
    run
    run(params: ActionController::Parameters.new(proxy_mate_setting: { url: 'https://other.example.com', api_key: '' }))

    setting = ProxyMateSetting.sole
    expect(setting.api_key).to eq('pm_AbCdEfGhIjKl')
    expect(setting.url).to eq('https://other.example.com')
  end

  it 'replaces the key when a new one is given' do
    run
    run(params: ActionController::Parameters.new(proxy_mate_setting: { api_key: 'pm_NewKeyNewKey' }))

    expect(ProxyMateSetting.sole.api_key).to eq('pm_NewKeyNewKey')
    expect(ProxyMateSetting.sole.url).to eq('https://pm.example.com')
  end

  it 'rejects a URL that is not http(s) and saves no value' do
    result = run(params: ActionController::Parameters.new(proxy_mate_setting: { url: 'proxymate.local' }))

    expect(result).to be_failure
    expect(result.errors[:url]).to include(I18n.t('admin.proxy_mate_setting.errors.invalid_url'))
    expect(ProxyMateSetting.pick(:url)).to be_nil
  end

  it 'is denied to a non-admin and creates nothing' do
    expect { run(user: create(:user)) }.to raise_error(Pundit::NotAuthorizedError)
    expect(ProxyMateSetting.count).to eq(0)
  end
end
