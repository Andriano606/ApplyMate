# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::AssessFormLikeness do
  let(:root) { 'form#apply' }

  def assess(elements, root: nil)
    described_class.call(elements: build_snapshot(elements:).elements, root:).model
  end

  def field(name, type: 'text', **state)
    snapshot_element(role: 'textbox', name:, type:, regions: [ root ], **state)
  end

  let(:application) { [ field('Full name'), field('Email', type: 'email'), field('Phone', type: 'tel') ] }

  it 'accepts three fillable fields one of which asks for the name or email' do
    expect(assess(application)).to have_attributes(accepted: true, reason: 'identity_field', fillable: 3, file_inputs: 0)
  end

  it 'accepts a form with a CV upload, even a hidden one' do
    cv = snapshot_element(role: nil, type: 'file', name: 'Resume', visible: false, self_visible: false, regions: [ root ])

    expect(assess([ cv ])).to have_attributes(accepted: true, reason: 'file_input', file_inputs: 1)
  end

  it 'rejects an email-only subscription box' do
    signup = [ field('Email', type: 'email'), snapshot_element(role: 'button', name: 'Subscribe', regions: [ root ]) ]

    expect(assess(signup)).to have_attributes(accepted: false, reason: 'too_few_fields', fillable: 1)
  end

  it 'rejects a sign-in form (a password field)' do
    login = [ field('Email', type: 'email'), field('Password', type: 'password'), field('Name') ]

    expect(assess(login)).to have_attributes(accepted: false, reason: 'password')
  end

  it 'rejects enough fields when none of them asks who the candidate is' do
    expect(assess([ field('City'), field('Company'), field('Budget') ])).to have_attributes(accepted: false, reason: 'no_identity_field')
  end

  it 'leaves site chrome (search-like), disabled and invisible controls and radio-group members out of the count' do
    search = field('Search jobs', type: 'search', search_like: true)
    header_email = field('Email', type: 'email', search_like: true)
    radios = %w[Yes No Maybe].map { |label| snapshot_element(role: 'radio', name: label, type: 'radio', group: 'radio_group', group_key: 'radio:relocate', regions: [ root ]) }
    hidden = field('Middle name', visible: false)
    disabled = field('Referral', disabled: true)

    verdict = assess([ field('First name'), search, header_email, *radios, hidden, disabled ])

    expect(verdict).to have_attributes(accepted: false, reason: 'too_few_fields', fillable: 2)
  end

  it 'narrows the elements to the root region when root: is given' do
    outside = [ field('Name', regions: []), field('Email', type: 'email', regions: []), field('Phone', regions: []) ]

    expect(assess(outside, root:)).to have_attributes(accepted: false, fillable: 0)
    expect(assess(application, root:)).to have_attributes(accepted: true)
  end

  it 'classifies through Answer::Classify (labels, placeholders, input kinds)' do
    by_placeholder = [ field('', attrs: { 'placeholder' => 'Your full name' }), field('Company'), field('Role') ]

    expect(assess(by_placeholder)).to have_attributes(accepted: true, reason: 'identity_field')
  end
end
