# frozen_string_literal: true

class Admin::Source::Component::Table < ApplyMate::Component::Base
  available_for :admin

  def initialize(sources:, **)
    @sources = sources
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @sources, empty_message: I18n.t('admin.source.index.empty'))

    table.add_column(header: I18n.t('admin.source.index.table.name'), &:name)

    table.add_column(header: I18n.t('admin.source.index.table.actions'), type: :actions) do |source|
      helpers.safe_join([
                          edit_table_button(link: helpers.edit_admin_source_path(source)),
                          delete_table_button(link: helpers.admin_source_path(source),
                                              confirm: I18n.t('admin.source.destroy.confirm'))
                        ], ' ')
    end

    render table
  end
end
