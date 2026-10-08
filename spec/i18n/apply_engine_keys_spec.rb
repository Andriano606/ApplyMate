# frozen_string_literal: true

require 'rails_helper'

# Every user-visible engine outcome must have localized text in both locales. Iterating the real tables means a
# new Halt code / state / stage without uk+en texts fails here, not in production.
RSpec.describe 'Apply engine locale keys' do
  locales = %w[uk en]

  stages = begin
    concepts = Rails.root.join('app/concepts')
    Dir[concepts.join('apply/operation/**/*.rb')].each do |file|
      concepts.join(file).relative_path_from(concepts).to_s.delete_suffix('.rb').camelize.constantize
    end
    # Spec-only fakes (spec/support/apply_engine_fakes.rb) are not part of the product's stages; abstract bases
    # (Apply::Operation::Stage::Base) declare none.
    Apply::Operation::Base.descendants.select { |klass| klass.name.start_with?('Apply::Operation::') }
                          .reject { |klass| klass.name.end_with?('::Base') }
                          .map { |klass| klass.stage.to_s }.uniq
  end

  def self.missing_keys(locales, keys)
    locales.product(keys).reject { |locale, key| I18n.exists?(key, locale) }
  end

  locales.each do |locale|
    describe "locale #{locale}" do
      Apply::Operation::Engine::Halt::CODES.each_key do |code|
        it "has failure text and hint for #{code}" do
          expect { I18n.t("apply.failure.#{code}", locale:, raise: true) }.not_to raise_error
          expect { I18n.t("apply.failure_hint.#{code}", locale:, raise: true) }.not_to raise_error
        end
      end

      Apply.states.each_key do |state|
        it "has a text for state #{state}" do
          expect { I18n.t("apply.state.#{state}", locale:, raise: true) }.not_to raise_error
        end
      end

      stages.each do |stage|
        it "has a text for stage #{stage}" do
          expect { I18n.t("apply.stage.#{stage}", locale:, raise: true) }.not_to raise_error
        end
      end
    end
  end

  it 'discovers the pipeline stages (guards the iteration above against being vacuous)' do
    expect(stages).to include('check_applyable', 'submit', 'detect', 'schema')
  end

  it 'detects a Halt code without texts (the iteration is not vacuous)' do
    expect { I18n.t('apply.failure.no_such_code', locale: 'uk', raise: true) }.to raise_error(I18n::MissingTranslationData)
    expect(self.class.missing_keys(locales, %w[apply.failure.no_such_code])).not_to be_empty
  end

  it 'has no Cyrillic in the English apply texts' do
    cyrillic = []
    walk = lambda do |node, path|
      case node
      when Hash then node.each { |key, value| walk.call(value, "#{path}.#{key}") }
      when Array then node.each_with_index { |value, index| walk.call(value, "#{path}[#{index}]") }
      when String then cyrillic << path if node.match?(/\p{Cyrillic}/)
      end
    end
    walk.call(I18n.t('apply', locale: :en), 'en.apply')

    expect(cyrillic).to be_empty
  end
end
