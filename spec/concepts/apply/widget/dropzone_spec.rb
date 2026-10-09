# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::Dropzone, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:dir) { Dir.mktmpdir('widget-spec') }
  let(:resume) { File.join(dir, 'resume.pdf').tap { |path| File.write(path, '%PDF-1.4 fake') } }

  after { FileUtils.remove_entry(dir) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'uploads through the file chooser of a button without a file input and reads the file name back' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'Upload resume')
      allow(session).to receive(:upload).and_call_original

      expect(field).to have_attributes(kind: 'file', widget: 'dropzone')
      expect(set!(field, resume).displayed).to include('resume.pdf')
      expect(session).to have_received(:upload).with(field.target, resume, via_chooser: true)
    end
  end

  it 'flags only the upload button as a chooser' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, _fields|
      choosers = session.snapshot_all.elements.select { |element| element['chooser'] }

      expect(choosers.pluck('name')).to eq([ 'Upload resume' ])
    end
  end
end
