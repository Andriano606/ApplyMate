# frozen_string_literal: true

class RenameCvMarkdownToRawCvInApplies < ActiveRecord::Migration[8.1]
  def change
    rename_column :applies, :cv_markdown, :raw_cv
  end
end
