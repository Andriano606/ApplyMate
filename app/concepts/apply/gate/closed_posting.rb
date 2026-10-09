# frozen_string_literal: true

# The posting is closed (design §10.4): a frame's outline / alerts say so (CLOSED_LEXICON) AND that frame has no
# visible fillable control. A form page with a "this position is closed" line in its footer stays silent: the control
# test is Engine::BuildFieldInventory.control?, the one definition of "fillable". -> Halt(:closed_posting, detail: the
# matched text).
class Apply::Gate::ClosedPosting < Apply::Gate::Base
  CLOSED_LEXICON = Regexp.union(
    /no longer accepting applications/i,
    /this (job|position|posting|role) (is no longer available|has been (closed|filled))/i,
    /position (is )?closed/i,
    /вакансі[яю] закрит/i,
    /вакансия закрыта/i,
    /набір закрито/i,
    /прийом (заявок|резюме) (закрит|завершен)/i
  ).freeze

  def self.events
    %i[after_goto after_action]
  end

  def call(_ctx, snapshot: nil, **)
    return if snapshot.nil?

    snapshot.frames.each do |frame|
      matched = closed_text(frame)
      halt!(:closed_posting, detail: matched) if matched && !fillable?(snapshot, frame)
    end
    nil
  end

  private

  def closed_text(frame)
    text = (Array(frame['outline']) + Array(frame['alerts'])).join("\n")
    text[CLOSED_LEXICON]
  end

  def fillable?(snapshot, frame)
    snapshot.elements.any? do |element|
      element['frame'] == frame['ref'] && element['visible'] &&
        Apply::Operation::Engine::BuildFieldInventory.control?(element)
    end
  end
end
