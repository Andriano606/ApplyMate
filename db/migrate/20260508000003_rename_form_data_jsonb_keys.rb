# frozen_string_literal: true

class RenameFormDataJsonbKeys < ActiveRecord::Migration[8.0]
  def up
    # 'method' shadows Object#method — rename to http_method
    execute <<~SQL
      UPDATE applies
      SET form_data = jsonb_set(form_data - 'method', '{http_method}', form_data->'method')
      WHERE form_data ? 'method';
    SQL

    # filled_form_data uses the same 'inputs' key as form_data;
    # rename it so each column gets a unique typed accessor
    execute <<~SQL
      UPDATE applies
      SET filled_form_data = jsonb_set(filled_form_data - 'inputs', '{filled_inputs}', filled_form_data->'inputs')
      WHERE filled_form_data ? 'inputs';
    SQL
  end

  def down
    execute <<~SQL
      UPDATE applies
      SET form_data = jsonb_set(form_data - 'http_method', '{method}', form_data->'http_method')
      WHERE form_data ? 'http_method';
    SQL

    execute <<~SQL
      UPDATE applies
      SET filled_form_data = jsonb_set(filled_form_data - 'filled_inputs', '{inputs}', filled_form_data->'filled_inputs')
      WHERE filled_form_data ? 'filled_inputs';
    SQL
  end
end
