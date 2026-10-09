# frozen_string_literal: true

# A widget wrote a value but the control does not show it (read-back, design §7.2): maxlength cut it, a mask
# rewrote it, a framework reset it, no listbox option matched, the control reports itself invalid. Raised by
# Apply::Operation::Engine::SetFieldValue (after the driver's fallback) and by drivers that find nothing to pick;
# Stage::FillFields first tries Engine::RecoverField, then turns it into Halt(:required_field_unfillable) for a required
# field and an `unfilled` trace otherwise. The message never carries the value (applicant data); `wanted` / `read_back`
# are for the caller only.
#
# `before`: the ApplyMate::Client::Browser::Snapshot GuardAction took right before SetFieldValue's first write (nil
# when the mismatch did not come out of SetFieldValue): RecoverField shows the AI what is NEW since that write
# (an opened menu, a portaled listbox).
class Apply::Widget::Mismatch < StandardError
  attr_reader :field, :wanted, :read_back
  attr_accessor :before

  # read_back: Apply::Widget::Base::ReadBack, or nil when nothing could be written (no option matched)
  def initialize(field:, wanted:, read_back:)
    @field = field
    @wanted = wanted
    @read_back = read_back
    super("field #{field.id} (#{field.kind}) did not take the value#{" (#{read_back.error_text})" if read_back&.error_text.present?}")
  end
end
