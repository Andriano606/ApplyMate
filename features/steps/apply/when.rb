# frozen_string_literal: true

# Exit buttons of an apply card post through Turbo with a confirm dialog.
When('I click {string} on the last Apply card and confirm') do |text|
  accept_confirm do
    last_apply_card.find(:link_or_button, text, match: :first).click
  end
end
