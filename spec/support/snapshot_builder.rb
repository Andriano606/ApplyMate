# frozen_string_literal: true

# A real ApplyMate::Client::Browser::Snapshot for step specs, built by the PRODUCTION Operation::SnapshotAll from
# canned probe/snapshot.js output (refs "f<frame>:e<index>", fingerprints, Targets with frame paths, digest: exactly
# what Session#snapshot_all returns). Included in every spec (RSpec.configure at the bottom).
#
#   snapshot = build_snapshot(
#     frames: [ { url: 'https://acme.example/jobs/1' },
#               { url: 'https://ats.example/embed', element_id: 'ats_iframe', parent: 0 } ],
#     elements: [ snapshot_element(role: 'link', name: 'Apply', href: '/apply'),
#                 snapshot_element(role: 'textbox', name: 'Email', type: 'email', frame: 1, regions: [ 'form#apply' ]) ]
#   )
#   FakeSession.new(html: '', final_url: url, snapshot:)
#
# frames: main frame first; url, element_id (the <iframe>'s id: an iframe#id hop), parent (frame index), title,
# outline, alerts, captcha, password_fields (default: visible password elements of the frame).
# snapshot_element: one probe element with every key snapshot.js returns, sensible defaults for `role` / `type`
# (tag, filled), overridable by keyword (any probe key, e.g. submit_like: true, in_viewport: false, group_key: 'g').
# Strategies: { attr: { id } } when `id:`, { role, name } when named, then { css: } (default a unique
# `[data-spec=...]` selector; pass a `tag:nth-of-type` chain as `css:` where the spec needs DOM ancestry).
module SnapshotBuilder
  DEFAULT_URL = 'https://acme.example/jobs/1'
  INPUT_ROLES = %w[textbox combobox checkbox radio switch searchbox spinbutton slider].freeze

  # Driver#evaluate_all_frames stand-in: returns the canned per-frame results.
  class CannedDriver
    def initialize(raw)
      @raw = raw
    end

    def evaluate_all_frames(_script, _arg)
      @raw
    end
  end

  def build_snapshot(frames: [ {} ], elements: [], markers: [])
    raw = frames.each_with_index.map do |frame, index|
      own = elements.select { |element| element.fetch('frame_index', 0) == index }
                    .each_with_index.map { |element, position| element.except('frame_index').merge('index' => position) }
      canned_frame(frame, index, own)
    end
    ApplyMate::Client::Browser::Operation::SnapshotAll.call(driver: CannedDriver.new(raw), markers:).model
  end

  def snapshot_element(role: 'textbox', name: '', type: nil, tag: nil, frame: 0, id: nil, css: nil, href: nil,
                       regions: [], **state)
    type ||= 'text' if role == 'textbox' && tag.nil?
    tag ||= default_tag(role, type)
    field = %w[input textarea select].include?(tag) || INPUT_ROLES.include?(role)
    strategies = []
    strategies << { 'attr' => { 'id' => id } } if id
    strategies << { 'role' => role, 'name' => name } if role && name.present?
    strategies << { 'css' => css || "#{tag}[data-spec=\"#{frame}-#{role}-#{name.parameterize}-#{type}\"]" }
    {
      'frame_index' => frame, 'tag' => tag, 'type' => type, 'role' => role, 'name' => name, 'question' => nil,
      'required' => false, 'invalid' => false, 'checked' => nil, 'expanded' => nil, 'pressed' => nil, 'selected' => nil,
      'disabled' => false, 'readonly' => false, 'visible' => true, 'self_visible' => true, 'in_viewport' => true,
      'aria_hidden' => false, 'filled' => field ? false : nil, 'group' => nil, 'group_key' => nil,
      'password' => type == 'password', 'search_like' => false, 'submit_like' => false, 'href' => href, 'options' => nil,
      'chip' => nil, 'strategies' => strategies, 'root_strategies' => nil, 'regions' => regions,
      'attrs' => { 'id' => id, 'name' => nil, 'type' => type, 'autocomplete' => nil, 'placeholder' => nil, 'accept' => nil,
                   'multiple' => false, 'maxlength' => nil, 'value' => nil, 'data-field-path' => nil }
    }.merge(state.deep_stringify_keys)
  end

  private

  def default_tag(role, type)
    return 'input' if type.present?

    case role
    when 'link' then 'a'
    when 'button', 'tab' then 'button'
    when 'textbox', 'combobox', 'checkbox', 'radio' then 'input'
    else 'div'
    end
  end

  def canned_frame(frame, index, elements)
    url = frame.fetch(:url, index.zero? ? DEFAULT_URL : "https://frame#{index}.example/")
    passwords = elements.count { |element| element['password'] && element['visible'] }
    snapshot = {
      'frame' => { 'url' => url, 'title' => frame.fetch(:title, "page #{index}") },
      'outline' => frame.fetch(:outline, []), 'alerts' => frame.fetch(:alerts, []), 'captcha' => frame.fetch(:captcha, []),
      'password_fields' => frame.fetch(:password_fields, passwords), 'truncated' => false, 'elements' => elements
    }
    detect = { 'script_srcs' => [], 'iframe_srcs' => [], 'dom_markers' => {} }
    { index:, url:, name: '', parent_index: frame.fetch(:parent, index.zero? ? nil : 0), element_id: frame[:element_id],
      value: { 'snapshot' => snapshot, 'detect' => detect } }
  end
end

RSpec.configure { |config| config.include SnapshotBuilder }
