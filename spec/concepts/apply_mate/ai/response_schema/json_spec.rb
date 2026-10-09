# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::ResponseSchema::Json do
  let(:invalid) { described_class::InvalidResponse }

  let(:schema_class) do
    stub_const('TestJsonSchema', Class.new(described_class) do
      def self.json_schema
        {
          type:                 'object',
          required:             %w[ok note],
          properties:           {
            ok:   { type: 'boolean' },
            note: { type: %w[string null] }
          },
          additionalProperties: false
        }
      end
    end)
  end

  describe '.extract' do
    it 'parses a ```json fence and returns indifferent access' do
      result = schema_class.extract("```json\n{\"ok\": true, \"note\": \"hi\"}\n```")

      expect(result).to eq('ok' => true, 'note' => 'hi')
      expect(result[:ok]).to be(true)
    end

    it 'parses a bare ``` fence' do
      expect(schema_class.extract("```\n{\"ok\": false, \"note\": null}```")).to eq('ok' => false, 'note' => nil)
    end

    it 'parses bare JSON (native-schema answers)' do
      expect(schema_class.extract('{"ok":true,"note":null}')).to eq('ok' => true, 'note' => nil)
    end

    it 'narrows prose-wrapped JSON to the outermost object' do
      raw = 'Sure! Here it is: {"ok": true, "note": "nested {braces}"} Hope [this] helps.'

      expect(schema_class.extract(raw)).to eq('ok' => true, 'note' => 'nested {braces}')
    end

    it 'ignores a [ in the prose before the object (CSS selector)' do
      raw = "The button a[href*=apply] opens the form.\n{\"ok\": true, \"note\": \"a[href*=apply]\"}"

      expect(schema_class.extract(raw)).to eq('ok' => true, 'note' => 'a[href*=apply]')
    end

    it 'accepts null for a nullable field' do
      expect(schema_class.extract('{"ok": true, "note": null}')[:note]).to be_nil
    end

    it 'raises on a blank answer' do
      expect { schema_class.extract("  \n") }.to raise_error(invalid, 'blank AI response')
    end

    it 'raises with the parser message on invalid JSON' do
      expect { schema_class.extract('{"ok": tru') }.to raise_error(invalid, /not valid JSON/)
    end

    it 'raises when there is no JSON at all' do
      expect { schema_class.extract('I cannot help with that.') }.to raise_error(invalid, /not valid JSON/)
    end

    it 'raises on a missing required key' do
      expect { schema_class.extract('{"ok": true}') }.to raise_error(invalid, /note/)
    end

    it 'raises on a wrong type' do
      expect { schema_class.extract('{"ok": "yes", "note": null}') }.to raise_error(invalid, /ok/)
    end

    it 'raises on an undeclared key when additionalProperties is false' do
      expect { schema_class.extract('{"ok": true, "note": null, "extra": 1}') }.to raise_error(invalid, /extra/)
    end

    it 'never opens a JSON string answer as a URI or file' do
      allow(URI).to receive(:open)
      allow(File).to receive(:read).and_call_original

      expect { schema_class.extract('"/etc/passwd"') }.to raise_error(invalid)
      expect(URI).not_to have_received(:open)
      expect(File).not_to have_received(:read).with('/etc/passwd')
    end
  end

  describe '.native_schema?' do
    it 'is true for a schema with fixed properties' do
      expect(schema_class.native_schema?).to be(true)
    end

    it 'is false for an additionalProperties-only schema' do
      dynamic = Class.new(described_class) do
        def self.json_schema
          { type: 'object', additionalProperties: { type: 'string' } }
        end
      end

      expect(dynamic.native_schema?).to be(false)
    end
  end

  it 'requires subclasses to declare json_schema' do
    expect { Class.new(described_class).extract('{}') }.to raise_error(NotImplementedError)
  end

  it 'leaves non-JSON schemas without a schema' do
    expect(ApplyMate::Ai::ResponseSchema::Base).to have_attributes(json_schema: nil, native_schema?: false)
  end
end
