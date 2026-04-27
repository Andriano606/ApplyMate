# frozen_string_literal: true

class SourceProfile::Component::Table < ApplyMate::Component::Base
  def initialize(source_profiles:, **)
    @source_profiles = source_profiles
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @source_profiles, empty_message: I18n.t('components.table.empty'))

    table.add_column(header: I18n.t('source_profile.index.table.source')) do |sp|
      helpers.content_tag(:span, sp.source.name, class: 'font-medium')
    end

    table.add_column(header: I18n.t('source_profile.index.table.name')) do |sp|
      sp.name
    end

    table.add_column(header: I18n.t('source_profile.index.table.auth_method')) do |sp|
      sp.auth_method
    end

    table.add_column(header: I18n.t('source_profile.index.table.actions'), type: :actions) do |sp|
      helpers.safe_join([
        edit_table_button(link: helpers.edit_source_profile_path(sp)),
        delete_table_button(link: helpers.source_profile_path(sp), confirm: I18n.t('source_profile.destroy.confirm'))
      ], ' ')
    end

    render table
  end
end
