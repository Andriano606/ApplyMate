# frozen_string_literal: true

# Runs probe/listbox.js in the field's frame and in the top document (react-select and Element UI portal their menus
# to the top body). model = { scope => { 'containers' => { key => count }, 'options' => [option + 'target'] } },
# scope 'frame' (only when frame_path is not empty) and 'top'. `since` = the 'containers' maps of an earlier read
# (Session#dom_mark), per scope: only options new since then are returned. A scope that cannot be read (frame gone,
# navigating) reads as empty.
class ApplyMate::Client::Browser::Operation::ReadListbox < ApplyMate::Operation::Base
  EMPTY = { 'containers' => {}, 'options' => [] }.freeze

  def perform!(driver:, frame_path:, since: nil, **)
    skip_authorize
    scopes = frame_path.empty? ? { 'top' => [] } : { 'frame' => frame_path, 'top' => [] }
    self.model = scopes.to_h { |scope, path| [ scope, read(driver, path, since&.fetch(scope, nil)) ] }
  end

  private

  def read(driver, path, since)
    root_target = ApplyMate::Client::Browser::Target.css(':root', frame_path: path)
    root = ApplyMate::Client::Browser::Operation::Locate.call(driver:, target: root_target, visibility: :attached).model
    result = driver.probe(:listbox, root, { 'since' => since })
    options = result.fetch('options').map do |option|
      option.merge('target' => ApplyMate::Client::Browser::Target.new(frame_path: path, strategies: option['strategies'],
                                                                      root: nil, readonly: false))
    end
    { 'containers' => result.fetch('containers'), 'options' => options }
  rescue ApplyMate::Client::Browser::TargetNotFound, ::Playwright::Error
    EMPTY
  end
end
