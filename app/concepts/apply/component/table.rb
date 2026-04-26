# frozen_string_literal: true

class Apply::Component::Table < ApplyMate::Component::Base
  def initialize(applies:, **)
    @applies = applies
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @applies, empty_message: I18n.t('components.table.empty'))

    table.add_column(header: I18n.t('apply.index.table.vacancy')) do |apply|
      helpers.content_tag(:span, apply.vacancy.title, class: 'font-medium')
    end

    table.add_column(header: I18n.t('apply.index.table.company')) do |apply|
      apply.vacancy.company_name
    end

    table.add_column(header: I18n.t('apply.index.table.profile')) do |apply|
      apply.user_profile.name
    end

    table.add_column(header: I18n.t('apply.index.table.ai_integration')) do |apply|
      apply.ai_integration.provider.capitalize
    end

    table.add_column(header: I18n.t('apply.index.table.status')) do |apply|
      helpers.safe_join([
        Apply::TurboHandler::StatusUpdate.stream_from(apply, helpers),
        render(Apply::Component::StatusBadge.new(apply:))
      ])
    end

    table.add_column(header: I18n.t('apply.index.table.created_at')) do |apply|
      I18n.l(apply.created_at, format: :short)
    end

    table.add_column(header: I18n.t('apply.index.table.actions'), type: :actions) do |apply|
      helpers.safe_join([
        show_table_button(link: helpers.apply_path(apply)),
        delete_table_button(link: helpers.apply_path(apply), confirm: I18n.t('apply.destroy.confirm'))
      ], ' ')
    end

    render table
  end
end
