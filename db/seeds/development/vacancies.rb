# frozen_string_literal: true

require 'json'

source_ids = Source.pluck(:name, :id).to_h

Rails.root.join('db/seeds/development/vacancies.jsonl').each_line(chomp: true) do |line|
  next if line.strip.empty?

  attrs = JSON.parse(line).symbolize_keys
  source_id = source_ids.fetch(attrs.delete(:source_name))
  vacancies.upsert unique_by: %i[source_id external_id], source_id:, **attrs
end

Vacancy.import(force: true, refresh: true)
