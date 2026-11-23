# frozen_string_literal: true

# The button sits in the right side of the navbar (desktop and mobile menus both
# render it); it is clicked through JS like the generic `I click on` step.
When('I press the Connect Claude button in the navbar') do
  find(:link_or_button, I18n.t('navbar.connect_mcp'), visible: :all, match: :first)
    .execute_script('this.click()')
end

# The confirm is a native dialog (data-turbo-confirm).
When('I regenerate the MCP token and confirm') do
  accept_confirm do
    find('[data-test-id="mcp-regenerate-token"]').click
  end
end

# Remembers the token currently shown so a later step can prove it was replaced.
When('I remember the MCP token') do
  @mcp_token = User.last.personal_api_token.token
end
