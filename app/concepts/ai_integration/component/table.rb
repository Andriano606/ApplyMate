# frozen_string_literal: true

class AiIntegration::Component::Table < ApplyMate::Component::Base
  def initialize(ai_integrations:, **)
    @ai_integrations = ai_integrations
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @ai_integrations, empty_message: I18n.t('components.table.empty'))

    table.add_column(header: I18n.t('ai_integration.index.table.provider')) do |integration|
      helpers.content_tag(:span, integration.provider.capitalize.humanize, class: 'font-medium')
    end

    table.add_column(header: I18n.t('ai_integration.index.table.model'), &:model)

    table.add_column(header: I18n.t('ai_integration.index.table.created_at')) do |integration|
      I18n.l(integration.created_at, format: :short)
    end

    table.add_column(header: I18n.t('ai_integration.index.table.actions'), type: :actions) do |integration|
      helpers.safe_join([
        edit_table_button(link: helpers.edit_ai_integration_path(integration)),
        delete_table_button(link: helpers.ai_integration_path(integration), confirm: I18n.t('ai_integration.destroy.confirm'))
      ], ' ')
    end

    render table
  end
end
