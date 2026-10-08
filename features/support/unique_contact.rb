# frozen_string_literal: true

require Rails.root.join('spec/support/unique_contact').to_s

# Gherkin cannot call Ruby, so a feature names a generated contact with a placeholder: <unique_email:admin> or
# <unique_phone:main>. The first use in a scenario generates the value, every later use of the same name returns the
# same one (the OAuth user's email in a Given and the lookup of that user in a later step), and a new scenario
# generates a new one. Steps that take such a value pass it through expand_unique.
module UniqueContactWorld
  include UniqueContact

  UNIQUE_PLACEHOLDER = /<unique_(email|phone):([\w-]+)>/

  def expand_unique(text)
    text.gsub(UNIQUE_PLACEHOLDER) do
      kind = Regexp.last_match(1)
      name = Regexp.last_match(2)
      (@unique_contacts ||= {})[[ kind, name ]] ||= kind == 'email' ? unique_email(name) : unique_phone
    end
  end
end

World(UniqueContactWorld)

# The signed-in user of "I am logged in as Andrii Kuluev" gets a fresh address in every scenario.
Before do
  OmniAuth.config.mock_auth[:google_oauth2].info.email = unique_email('andrii')
end
