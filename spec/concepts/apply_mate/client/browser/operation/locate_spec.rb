# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::Locate, :browser do
  let(:target_class) { ApplyMate::Client::Browser::Target }
  let(:owner) { "#{ApplyMate::Client::Browser::Browserd.owner_prefix}#{Process.pid}:locate-spec" }

  around do |example|
    lease = ApplyMate::Client::Browser::Operation::AcquireLease.call(owner:).model
    @driver = ApplyMate::Client::Browser::Driver::Playwright.new(lease:, deadline: 2.minutes.from_now)
    @driver.start
    example.run
  ensure
    @driver&.close
  end

  # In a before hook: the PublicAddressGuard seam for the fixture host (browser_tag.rb) is installed per example.
  before { ApplyMate::Client::Browser::Operation::Goto.call(driver: @driver, url: FixtureSite.url(page_path)) }

  let(:page_path) { '/form.html' }

  def locate(visibility: :required, **target)
    described_class.call(driver: @driver, target: target_class.from_h(target), visibility:).model
  end

  def id_of(locator)
    @driver.probe(:outer_html, locator)[/\bid="([^"]+)"/, 1]
  end

  it 'resolves attr, role, label and css strategies' do
    expect(id_of(locate(strategies: [ { 'attr' => { 'data-qa' => 'email-input' } } ]))).to eq('email')
    expect(id_of(locate(strategies: [ { 'role' => 'textbox', 'name' => 'Full name' } ]))).to eq('full_name')
    expect(id_of(locate(strategies: [ { 'label' => 'Cover letter' } ]))).to eq('cover')
    expect(id_of(locate(strategies: [ { 'css' => 'input[type=radio]', 'nth' => 1 } ]))).to eq('relocate_no')
  end

  it 'skips strategies that match zero or several elements, and invalid selectors' do
    locator = locate(strategies: [ { 'css' => '#missing' }, { 'css' => 'button[type=submit]' }, { 'css' => 'a[[' },
                                   { 'attr' => { 'bad name"]' => 'x' } }, { 'css' => 'button', 'has_text' => 'Subscribe' } ])

    expect(locator.text_content).to eq('Subscribe')
  end

  it 'requires visibility for :required and only presence for :attached' do
    hidden = { strategies: [ { 'css' => '#remote' } ] }

    expect { locate(**hidden) }.to raise_error(ApplyMate::Client::Browser::TargetNotFound)
    expect(id_of(locate(visibility: :attached, **hidden))).to eq('remote')
  end

  it 'judges a styled control by its visible root' do
    styled = { strategies: [ { 'css' => '#remote' } ], root: [ { 'css' => '#remote-root' } ] }

    expect(id_of(locate(**styled))).to eq('remote')
    expect { locate(**styled, root: [ { 'css' => '#missing-root' } ]) }
      .to raise_error(ApplyMate::Client::Browser::TargetNotFound, /field root is not visible/)
  end

  context 'with a hidden duplicate of a visible control (responsive markup)' do
    let(:page_path) { '/responsive.html' }
    let(:by_name) { { 'attr' => { 'name' => 'email' } } }

    it 'counts hidden matches too, so a target resolves to the same element in both modes' do
      target = { strategies: [ by_name, { 'css' => '#email_desktop' } ] }

      expect(id_of(locate(**target))).to eq('email_desktop')
      expect(id_of(locate(visibility: :attached, **target))).to eq('email_desktop')
    end

    it 'treats the duplicate as ambiguous in both modes' do
      %i[required attached].each do |visibility|
        expect { locate(visibility:, strategies: [ by_name ]) }
          .to raise_error(ApplyMate::Client::Browser::TargetNotFound) { |error| expect(error).to be_ambiguous }
      end
    end
  end

  it 'reports a target matching nothing as not ambiguous' do
    expect { locate(strategies: [ { 'css' => '#missing' } ]) }
      .to raise_error(ApplyMate::Client::Browser::TargetNotFound) { |error| expect(error).not_to be_ambiguous }
  end

  context 'with an iframe' do
    let(:page_path) { '/iframe.html' }

    it 'follows a name hop and fails on an unknown frame' do
      @driver.wait_for_network_idle(timeout_ms: 5_000)

      expect(id_of(locate(frame_path: [ { 'name' => 'embedded-form' } ], strategies: [ { 'label' => 'Email' } ])))
        .to eq('email')
      expect { locate(frame_path: [ { 'url_contains' => 'nowhere.example' } ], strategies: [ { 'css' => 'input' } ]) }
        .to raise_error(ApplyMate::Client::Browser::TargetNotFound, /no frame matches/)
    end
  end

  it 'rejects an unknown visibility mode' do
    expect { locate(visibility: :visible, strategies: [ { 'css' => '#email' } ]) }.to raise_error(ArgumentError)
  end
end
