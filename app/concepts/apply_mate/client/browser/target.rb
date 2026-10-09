# Driver-neutral address of one element, resolved by Operation::Locate.
#   frame_path: hops from the top document to the element's frame, top -> leaf:
#               { 'selector' => 'iframe#x' } | { 'url_contains' => 'ashbyhq.com' } | { 'name' => 'frame-name' }
#   strategies: tried in order; one is accepted only when it matches exactly one element:
#               { 'css' => sel, 'has_text' => text?, 'nth' => n? } | { 'role' => role, 'name' => name? } |
#               { 'label' => text } | { 'attr' => { name => value } }
#   root:       strategies of the field root; for styled controls :required visibility is judged on it
#   readonly:   the field must not be written
ApplyMate::Client::Browser::Target = Data.define(:frame_path, :strategies, :root, :readonly) do
  def self.from_h(hash)
    hash = hash.deep_stringify_keys
    new(frame_path: hash.fetch('frame_path', []), strategies: hash.fetch('strategies'), root: hash['root'],
        readonly: hash.fetch('readonly', false))
  end

  def self.css(selector, has_text: nil, nth: nil, frame_path: [])
    strategy = { 'css' => selector, 'has_text' => has_text, 'nth' => nth }.compact
    new(frame_path:, strategies: [ strategy ], root: nil, readonly: false)
  end

  def readonly?
    readonly
  end

  def to_h
    { 'type' => 'browser', 'frame_path' => frame_path, 'strategies' => strategies, 'root' => root,
      'readonly' => readonly }
  end
end
