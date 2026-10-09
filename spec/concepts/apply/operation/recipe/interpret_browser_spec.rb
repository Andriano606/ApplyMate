# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Recipe::Interpret, :browser do
  let(:apply) { create(:apply, entry_url: FixtureSite.url('/new_tab.html')) }
  let(:ctx) { engine_context(apply) }
  let(:target) { ApplyMate::Client::Browser::Target }
  let(:ops) do
    [
      { 'op' => 'goto', 'url_template' => '{entry_url}' },
      { 'op' => 'click', 'target' => target.css('a#open-form', has_text: 'Apply').to_h },
      { 'op' => 'wait_for', 'root' => 'form#apply', 'frame_path' => [], 'min_fields' => 3 }
    ]
  end

  it 'follows a link that opens a new tab: switches to it, records switch_tab, and the session works on the new page' do
    in_fixture_scope(ctx) do |session|
      session.network_watch(%r{/newsletter\z}) # registered on the first page's tracker

      performed = described_class.call(ctx:, ops:).model

      expect(performed).to eq([ ops[0], ops[1], { 'op' => 'switch_tab', 'index' => 1 }, ops[2] ])
      expect(session.pages).to eq([ { 'url' => FixtureSite.url('/new_tab.html') }, { 'url' => FixtureSite.url('/form.html') } ])
      expect(session.current_url).to eq(FixtureSite.url('/form.html'))
      expect(ctx).to have_attributes(form_root: target.css('form#apply'), form_url: FixtureSite.url('/form.html'))
      expect(session.html).to include('Apply for Ruby Developer')

      mark = session.network_mark
      session.click(target.css('#newsletter button'))
      expect(session.settle(:click)).to include(quiet: true)
      posts = session.network_since(mark, bodies: true)
      expect(posts).to contain_exactly(include(method: 'POST', url: FixtureSite.url('/newsletter'), status: 404, body: 'not found'))
    end
  end

  it 'replays the recorded navigation (with its switch_tab) on a fresh lease' do
    in_fixture_scope(ctx) do
      @recorded = described_class.call(ctx:, ops:).model
    end

    in_fixture_scope(ctx) do |session|
      expect(described_class.call(ctx:, ops: @recorded).model).to eq(@recorded)
      expect(session.current_url).to eq(FixtureSite.url('/form.html'))
    end
  end
end
