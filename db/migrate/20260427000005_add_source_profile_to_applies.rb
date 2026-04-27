# frozen_string_literal: true

class AddSourceProfileToApplies < ActiveRecord::Migration[8.1]
  def change
    add_reference :applies, :source_profile, null: false, foreign_key: true
  end
end
