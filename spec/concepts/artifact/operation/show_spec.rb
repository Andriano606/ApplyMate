# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Artifact::Operation::Show, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let(:apply)        { create(:apply, user: current_user) }
  let(:owner)        { 'apply' }
  let(:name)         { 'cv' }
  let(:record)       { apply }
  let(:params)       { { owner:, id: record.hashid, name: }.merge(extra_params) }
  let(:extra_params) { {} }

  before do
    apply.cv.attach(io: StringIO.new('%PDF-1.4'), filename: 'cv.pdf', content_type: 'application/pdf')
    allow(ActiveStorage::Current).to receive(:url_options).and_return(host: 'example.com')
  end

  # The test service is Disk: its URL carries a signed token holding the key, disposition and expiry.
  def disk_token(url)
    encoded = url[%r{/disk/([^/]+)--}, 1]
    JSON.parse(Base64.urlsafe_decode64(encoded))
  end

  it 'returns a short-lived inline URL for the blob' do
    expect(result).to be_success
    token = disk_token(model.url)
    expect(token.dig('_rails', 'data', 'key')).to eq(apply.cv.blob.key)
    expect(token.dig('_rails', 'data', 'disposition')).to start_with('inline')
  end

  context 'with the attachment disposition' do
    let(:extra_params) { { disposition: 'attachment' } }

    it 'asks for a download' do
      expect(disk_token(model.url).dig('_rails', 'data', 'disposition')).to start_with('attachment')
    end
  end

  it 'expires within the five minute window' do
    expires_at = Time.zone.parse(disk_token(model.url).dig('_rails', 'exp'))
    expect(expires_at).to be_within(10.seconds).of(5.minutes.from_now)
  end

  context 'with a screenshot' do
    let(:name) { 'screenshot' }

    it 'is not found when nothing is attached' do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'with a vacancy cv' do
    let(:owner)  { 'vacancy_cv' }
    let(:record) do
      create(:vacancy_cv, user_profile: create(:user_profile, user: current_user)).tap do |cv|
        cv.cv.attach(io: StringIO.new('%PDF-1.4'), filename: 'cv.pdf', content_type: 'application/pdf')
      end
    end

    it 'returns a URL' do
      expect(model.url).to include(record.cv.blob.key).or include('/rails/active_storage/disk/')
    end
  end

  context 'with a record of another user' do
    let(:record) { create(:apply) }

    it 'is not found' do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'with an unknown owner' do
    let(:owner) { 'user' }

    it 'is not found' do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  context 'with a name the owner does not expose' do
    let(:owner) { 'vacancy_cv' }
    let(:name)  { 'screenshot' }
    let(:record) { create(:vacancy_cv, user_profile: create(:user_profile, user: current_user)) }

    it 'is not found' do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
