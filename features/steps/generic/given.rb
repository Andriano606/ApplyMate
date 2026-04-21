# frozen_string_literal: true

# Helper to convert string values to appropriate types
def convert_table_value(value)
  case value
  when /\A\d+\z/ then value.to_i
  when /\A\d+\.\d+\z/ then value.to_f
  when 'true' then true
  when 'false' then false
  when /\A[\[{]/ then JSON.parse(value)
  else value
  end
end

# Generic step for creating model records from a table
# Examples:
#   Given the following Printer records:
#     | name       | print_width | print_depth | print_height |
#     | Prusa MK3S | 250         | 210         | 210          |
#
#   Given the following Material records:
#     | name |
#     | PLA  |
Given('the following {word} records:') do |model_name, table|
  model_class = model_name.constantize
  table.hashes.each do |attributes|
    typed_attrs = attributes.transform_values { |v| convert_table_value(v) }
    model_class.find_or_create_by!(typed_attrs)
  end
end

# Generic step for updating a model record.
# Supports finding by attribute or using the last record.
# Table format: each row is | attribute | value |
#
# Examples:
#   Given the User with email "test@example.com" has:
#     | admin | true |
#
#   Given the last PrintOrderFile record has:
#     | analysis_status       | done |
#     | glb_conversion_status | done |
Given(/^the (?:(last) )?(\w+)(?: with (\w+) "([^"]+)")?(?:\s+record)? has:$/) do |last, model_name, find_attr, find_value, table|
  model_class = model_name.constantize
  record = last ? model_class.last : model_class.find_by!(find_attr => find_value)
  table.rows_hash.each do |attr, value|
    record.update!(attr => convert_table_value(value))
  end
end

# Generic step for creating child records associated with the last parent record.
# Uses the parent model name (underscored) as the foreign key.
#
# Examples:
#   Given the last PrintOrderFile has the following PrintOrderFileModel records:
#     | colors      |
#     | ["#00AE42"] |
Given(/^the last (\w+) has the following (\w+) records:$/) do |parent_model, child_model, table|
  parent = parent_model.constantize.last
  child_class = child_model.constantize
  fk = "#{parent_model.underscore}_id"
  table.hashes.each do |attrs|
    typed_attrs = attrs.transform_values { |v| convert_table_value(v) }
    child_class.create!(typed_attrs.merge(fk => parent.id))
  end
end

Given('I am logged in as Andrii Kuluev') do
  visit '/auth/google_oauth2'
end

Given('the OAuth user is {string} with email {string}') do |name, email|
  OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
    provider: 'google_oauth2',
    uid: '123456789',
    info: {
      email: email,
      name: name
    }
  )
end
