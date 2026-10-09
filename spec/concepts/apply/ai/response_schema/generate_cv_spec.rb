# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::GenerateCv do
  let(:slot) { ApplyMate::Client::LocalChrome::SLOT }
  let(:answer) { "```html\n<!DOCTYPE html><html><body><h1>CV</h1></body></html>\n```" }
  let(:grover) { instance_double(Grover) }

  before { allow(Grover).to receive(:new).and_return(grover) }

  after { expect(slot.available_permits).to eq(1) }

  it 'renders the PDF while holding the process-wide local Chrome slot' do
    permits_during_render = nil
    allow(grover).to receive(:to_pdf) do
      permits_during_render = slot.available_permits
      '%PDF-1.4 cv'
    end

    expect(described_class.extract(answer)).to eq('%PDF-1.4 cv')
    expect(permits_during_render).to eq(0)
  end

  it 'lets LocalChrome::Busy through unchanged (transient capacity, not a parse failure) without rendering' do
    stub_const("#{described_class}::RENDER_SLOT_WAIT", 0.1)
    allow(grover).to receive(:to_pdf)
    slot.acquire
    begin
      expect { described_class.extract(answer) }.to raise_error(ApplyMate::Client::LocalChrome::Busy)
    ensure
      slot.release
    end
    expect(grover).not_to have_received(:to_pdf)
  end

  it 'still wraps an answer that is not an HTML document as a parse failure' do
    expect { described_class.extract('just text') }.to raise_error(RuntimeError, /Failed to parse AI GenerateCv response/)
  end

  it 'waits for the slot longer than one full GeminiScraping call' do
    expect(described_class::RENDER_SLOT_WAIT).to be > ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS
  end
end
