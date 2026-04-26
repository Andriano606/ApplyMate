# frozen_string_literal: true

class AddCvMarkdownToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :cv_markdown, :text
  end
end
