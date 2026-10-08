# The final URL of DetectPlatform's HTTP redirect walk, stored as fetched (like entry_url). The stage's step result
# goes through RedactTree, which mangles long digit runs in URLs, so a later attempt must not navigate by it.
class AddLandingUrlToApplies < ActiveRecord::Migration[8.1]
  def change
    add_column :applies, :landing_url, :string
  end
end
