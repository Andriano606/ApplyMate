# The "Connect Claude (MCP)" modal from the user menu (see .ai/docs/mcp.md).
# Every action answers with the same modal, replaced in place, so the copy
# button and the regenerate button always show the current token.
class McpConnectionsController < ApplicationController
  MODAL_ID = McpConnection::Component::Modal::MODAL_ID

  def show
    endpoint(McpConnection::Operation::Show) { |m| m.success { |result| render_modal(result) } }
  end

  def create
    endpoint(McpConnection::Operation::Create) { |m| m.success { |result| render_modal(result) } }
  end

  def update
    endpoint(McpConnection::Operation::Update) { |m| m.success { |result| render_modal(result) } }
  end

  private

  def render_modal(result)
    html = render_to_string(McpConnection::Component::Modal.new(**result.model.to_h), layout: false)
    actions = [
      turbo_stream.create_element_if_not_exist(target: MODAL_ID, parent_id: 'turbo-modals'),
      turbo_stream.replace(MODAL_ID, html:, method: :morph)
    ]
    actions << turbo_stream.flash([ [ result.message_level, result.notice[:text] ] ]) if result.notice
    render turbo_stream: actions
  end
end
