# frozen_string_literal: true

require 'rails_helper'

# The REAL snapshot.js + anchor.js, FormElements and ClassifyAdvance on generic/dialog_form.html (CleverStaff's
# AngularJS uib-modal: the final "Відгукнутися" is a type=button in .modal-footer OUTSIDE the <form>, wrapped in a
# <button-component role=button>, and the page has a launcher of the same name).
RSpec.describe Apply::Operation::Engine::ClassifyAdvance, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:url) { FixtureSite.url('/generic/dialog_form.html') }

  before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

  it "marks the dialog's apply verb submit_like (scope with fields) and never the page launcher" do
    on_fixture_form(ctx, url, form_root: 'form[name="sendForm"]') do |session, _fields|
      respond = session.snapshot_all.elements.select { |element| element['name'] == 'Відгукнутися' }

      dialog = respond.select { |element| element['scope'].to_s.start_with?('dialog') }
      expect(dialog.pluck('submit_like')).to include(true)
      expect(respond.select { |element| element['submit_like'] }.pluck('scope')).to all(start_with('dialog'))
      expect(respond.select { |element| element['scope'].nil? }.pluck('submit_like')).to all(be(false))
    end
  end

  it 'resolves the final button without its absolute nth-of-type path (scoped under the dialog, the native tag)' do
    on_fixture_form(ctx, url, form_root: 'form[name="sendForm"]') do |session, _fields|
      advance = described_class.call(ctx:).model
      expect(advance).to have_attributes(kind: :final, name: 'Відгукнутися')

      # A modal inserted at another body index breaks the positional path; what is left must still be unique.
      relative = advance.target.strategies.reject { |strategy| strategy['css'].to_s.start_with?('html') }
      expect { session.trial_click(advance.target.with(strategies: relative)) }.not_to raise_error
    end
  end
end
