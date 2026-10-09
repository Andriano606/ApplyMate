# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::FileInput, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:dir) { Dir.mktmpdir('widget-spec') }
  let(:cv_path) { File.join(dir, 'CV_Jane.pdf').tap { |path| File.write(path, '%PDF-1.4 fake') } }

  after { FileUtils.remove_entry(dir) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'uploads into a clipped file input and reads the file name back' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fields.find(&:file?)

      expect(field).to have_attributes(widget: 'file_input')
      expect(set!(field, cv_path).displayed).to eq('CV_Jane.pdf')
    end
  end

  it "uploads Ashby's resume behind the Upload File button" do
    on_fixture_form(ctx, FixtureSite.alt_url('/ashby/application.html?embed=js'), form_root: '#form[role="tabpanel"]') do |_session, fields|
      field = fixture_field(fields, 'Resume')

      expect(field).to have_attributes(kind: 'file', widget: 'file_input')
      expect(set!(field, cv_path).displayed).to eq('CV_Jane.pdf')
    end
  end
end
