# frozen_string_literal: true

class Admin::User::Component::Table < ApplyMate::Component::Base
  available_for :admin

  def initialize(users:, **)
    @users = users
  end

  def call
    render(table)
  end

  private

  attr_reader :users

  def table
    @table ||= ApplyMate::Component::Table.new(rows: users, empty_message: I18n.t('admin.user.index.empty')).tap do |t|
      t.add_column(header: I18n.t('admin.user.index.table.name')) do |user|
        helpers.content_tag(:span, user.name, class: 'font-medium')
      end

      t.add_column(header: I18n.t('admin.user.index.table.email')) do |user|
        user.email
      end

      t.add_column(header: I18n.t('admin.user.index.table.role')) do |user|
        if user.admin?
          helpers.content_tag(:span, I18n.t('admin.user.index.table.admin'), class: 'text-indigo-600 font-medium')
        else
          I18n.t('admin.user.index.table.customer')
        end
      end

      t.add_column(header: I18n.t('admin.user.index.table.actions'), type: :actions) do |user|
        next if current_user&.id == user.id

        helpers.button_to(
          I18n.t('admin.user.index.table.impersonate'),
          helpers.admin_impersonation_path,
          method: :post,
          params: { user_id: user.id },
          class: 'bg-amber-500 text-white px-3 py-1 rounded text-sm hover:bg-amber-600 transition-colors',
          data: { turbo: false }
        )
      end
    end
  end
end
