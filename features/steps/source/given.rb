# `the following {word} records:` uses find_or_create_by!, which cannot satisfy
# Source's required logo attachment.
Given('a job source exists') do
  create(:source)
end
