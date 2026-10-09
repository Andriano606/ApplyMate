# frozen_string_literal: true

# Writes one field and proves it took (design §7.2): the field's widget driver (Apply::Widget::Registry) writes the
# value inside GuardAction, the session settles with the driver's profile, and the driver reads the control back.
# Not accepted (driver.accepts?: the control is invalid or shows something else) -> the driver's fallback_write
# (again guarded, settled, read back); no fallback, or still not accepted -> Apply::Widget::Mismatch (field, wanted,
# read_back, `before` = the snapshot GuardAction took before the first write, for Engine::RecoverField). A write is
# never assumed to have worked.
#
# Termination: at most two writes (write, fallback). model = the accepted ReadBack; result[:approximate] = the option
# label the driver picked although it does not match the answer (Widget::Base#approximate_pick), else nil.
class Apply::Operation::Engine::SetFieldValue < ApplyMate::Operation::Base
  def perform!(ctx:, field:, value:, **)
    skip_authorize
    @ctx = ctx
    driver = Apply::Widget::Registry.for(field).new(ctx:, field:)
    self.model = begin
      write_and_verify(driver, value, -> { driver.write(value) })
    rescue Apply::Widget::Mismatch => e
      ctx.trace(:widget_fallback, field: field.id, widget: driver.class.key)
      write_and_verify(driver, value, -> { driver.fallback_write(value) || raise(e) })
    end
    result[:approximate] = driver.approximate_pick
  rescue Apply::Widget::Mismatch => e
    e.before ||= @before
    raise
  end

  private

  attr_reader :ctx

  def write_and_verify(driver, value, write)
    guarded_write(write)
    ctx.session.settle(driver.settle_kind)
    read_back = driver.read
    return read_back if driver.accepts?(read_back, value)

    raise Apply::Widget::Mismatch.new(field: driver.field, wanted: value, read_back:)
  end

  # A Mismatch the driver raises inside the guard (nothing to pick) is held until the guard returned, so its
  # pre-write snapshot is kept either way.
  def guarded_write(write)
    mismatch = nil
    action = lambda do
      write.call
    rescue Apply::Widget::Mismatch => e
      mismatch = e
    end
    guard = Apply::Operation::Engine::GuardAction.call(ctx:, action:)
    @before ||= guard[:snapshot]
    raise mismatch if mismatch
  end
end
