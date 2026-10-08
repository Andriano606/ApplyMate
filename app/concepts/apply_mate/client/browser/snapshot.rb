# frozen_string_literal: true

# Result of Session#snapshot_all (Operation::SnapshotAll): every frame of the page read by probe/snapshot.js and
# probe/detect.js.
#
# - frames:   [{ 'ref' => 'f0', 'index', 'url', 'title', 'parent' => nil | 'f0', 'frame_path', 'outline', 'alerts',
#               'captcha', 'password_fields', 'truncated', 'readable' }] in page.frames order (main frame first)
# - elements: the probe's elements of every frame, each with 'ref' ("f<frame>:e<index>"), 'frame' ("f<frame>"),
#             'fingerprint' ("role|name|f<frame>") and 'target' (a Target: frame_path + strategies, plus the field
#             root for styled / hidden controls whose visibility is judged on it, and readonly)
# - evidence: { frame_urls:, script_srcs:, iframe_srcs:, dom_markers: { selector => count over all frames } }
# - digest:   SHA1 of the fingerprints in order (did the page change between two snapshots?)
ApplyMate::Client::Browser::Snapshot = Data.define(:frames, :elements, :evidence, :digest)
