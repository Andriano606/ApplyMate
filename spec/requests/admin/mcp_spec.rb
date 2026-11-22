# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin MCP page', type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:token) { create(:api_token, user: admin, name: 'Laptop') }

  def visit_page(user)
    auth_token = user.api_tokens.first || create(:api_token, user:)
    get admin_mcp_path, headers: { 'Authorization' => "Bearer #{auth_token.token}" }
  end

  it "shows a ready-to-copy claude mcp add command with the admin's own token" do
    create(:api_token, name: 'Someone else') # tokens of other users never appear

    visit_page(admin)

    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    commands = page.css('[data-controller="clipboard"] [data-clipboard-target="source"]').map { |n| n.text.strip }
    expect(commands).to eq([
      %(claude mcp add --transport http --scope user applymate http://www.example.com/mcp ) +
        %(--header "Authorization: Bearer #{token.token}")
    ])
    expect(page.css('[data-action="click->clipboard#copy"]').size).to eq(1)
    expect(response.body).to include('Laptop')
    expect(response.body).not_to include('Someone else')
  end

  it 'lists every MCP tool' do
    visit_page(admin)

    Mcp::Operation::Handle::TOOLS.each { |tool| expect(response.body).to include(tool.tool_name) }
  end

  it 'falls back to a placeholder command and a create-token link when the admin has no token' do
    token.destroy!

    # The page is reached with a session in real life; here a throwaway token of a
    # second admin would leak into the list, so stub the token-less admin instead.
    allow_any_instance_of(Admin::McpController).to receive(:current_user).and_return(admin)
    get admin_mcp_path

    expect(response.body).to include('Bearer &lt;API_TOKEN&gt;', admin_api_tokens_path)
  end

  it 'is not available to regular users' do
    expect { visit_page(create(:user)) }.to raise_error(Pundit::NotAuthorizedError)
  end
end
