# frozen_string_literal: true

class Prompt::Component::Table < ApplyMate::Component::Base
  def initialize(prompts:, **)
    @prompts = prompts
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @prompts, empty_message: I18n.t('components.table.empty'))

    table.add_column(header: I18n.t('prompt.index.table.name')) do |p|
      helpers.content_tag(:span, p.name, class: 'font-medium')
    end

    table.add_column(header: I18n.t('prompt.index.table.prompt_type')) do |p|
      helpers.content_tag(:span, I18n.t("prompt.types.#{p.prompt_type}"), class: 'text-gray-600')
    end

    table.add_column(header: I18n.t('prompt.index.table.content_preview')) do |p|
      helpers.content_tag(:span, p.content.truncate(100), class: 'text-gray-500 font-mono text-sm')
    end

    table.add_column(header: I18n.t('prompt.index.table.actions'), type: :actions) do |p|
      helpers.safe_join([
        edit_table_button(link: helpers.edit_prompt_path(p)),
        delete_table_button(link: helpers.prompt_path(p), confirm: I18n.t('prompt.destroy.confirm'))
      ], ' ')
    end

    render table
  end
end
