# frozen_string_literal: true

require 'json'

Rails.root.join('db/seeds/development/prompts.jsonl').each_line(chomp: true) do |line|
  next if line.strip.empty?

  attrs = JSON.parse(line).symbolize_keys

  prompt = prompts.create unique_by: %i[user_id prompt_type name],
                          user_id: users.andrii.id,
                          **attrs

  case prompt.prompt_type
  when 'fill_form'   then users.andrii.update!(default_fill_form_prompt_id: prompt.id)
  when 'generate_cv' then users.andrii.update!(default_generate_cv_prompt_id: prompt.id)
  end
end
