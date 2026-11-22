# frozen_string_literal: true

class Admin::McpController < Admin::BaseController
  def show
    endpoint Admin::Mcp::Operation::Show, Admin::Mcp::Component::Show
  end
end
