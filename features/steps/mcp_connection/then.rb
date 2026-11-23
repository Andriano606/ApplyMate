# frozen_string_literal: true

MCP_COMMAND = '[data-test-id="mcp-command"]'
MCP_TOKEN_STATUS = '[data-test-id="mcp-token-status"]'

Then('the MCP command has a placeholder instead of a token') do
  expect(page).to have_css(MCP_COMMAND, text: Mcp::Component::ConnectCommand::TOKEN_PLACEHOLDER)
end

Then('the MCP token status says no token was created') do
  expect(page).to have_css(MCP_TOKEN_STATUS, text: I18n.t('mcp_connection.modal.no_token'))
end

Then('the MCP command contains the personal token of the last User') do
  # the token is created by an async request, so wait for the row before reading it
  wait_for { User.last.personal_api_token }.to be_present
  expect(page).to have_css(MCP_COMMAND, text: "Bearer #{User.last.personal_api_token.token}")
end

Then('the MCP token status says a token exists') do
  expect(page).to have_css(MCP_TOKEN_STATUS, text: I18n.t('mcp_connection.modal.never_used'))
end

Then('the MCP command no longer contains the earlier token') do
  expect(@mcp_token).to be_present
  expect(page).to have_no_css(MCP_COMMAND, text: @mcp_token)
end

Then('no personal MCP token exists') do
  expect(ApiToken.where(personal: true)).to be_empty
end

Then('the last User has {int} personal MCP token(s)') do |count|
  wait_for { User.last.api_tokens.where(personal: true).count }.to eq(count)
end
