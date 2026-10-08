# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::ResolveFact do
  let(:user_email) { unique_email('me') }
  let(:ai_phone) { unique_phone }
  let(:user_phone) { unique_phone }
  let(:user) { create(:user, email: user_email) }
  let(:profile) do
    create(:user_profile, user:, name: 'Profile Name',
                          facts: { 'ai' => { 'phone' => ai_phone, 'work_authorization' => 'EU citizen',
                                             'languages' => %w[English Ukrainian] },
                                   'user' => { 'phone' => user_phone, 'demographic' => 'Prefer to skip' } })
  end
  let(:apply) { create(:apply, user:, user_profile: profile) }

  def fact(semantic)
    described_class.call(semantic:, apply:).model
  end

  it 'prefers the user edit over the CV extraction' do
    expect(fact('phone')).to eq(user_phone)
  end

  it 'maps legal_status to work_authorization and reads the demographic fact' do
    expect(fact('legal_status')).to eq('EU citizen')
    expect(fact('demographic')).to eq('Prefer to skip')
  end

  it 'joins languages' do
    expect(fact('languages')).to eq('English, Ukrainian')
  end

  it 'falls back to the account email and the profile name' do
    expect(fact('email')).to eq(user_email)
    expect(fact('full_name')).to eq('Profile Name')
  end

  it 'returns the cv file reference' do
    expect(fact('cv')).to eq(Apply::Operation::Answer::FileRef.cv)
  end

  it 'is nil for a fact nobody knows and for semantics that are not facts' do
    expect(fact('github')).to be_nil
    expect(fact('cover_letter')).to be_nil
    expect(fact('consent_required')).to be_nil
    expect(fact('other')).to be_nil
  end
end
