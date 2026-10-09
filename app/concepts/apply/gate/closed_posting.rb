# frozen_string_literal: true

# The posting is closed (design §10.4): a frame's outline / alerts say so (CLOSED_LEXICON, uk / ru / en, both word
# orders: "Закрита вакансія" and "Вакансія закрита"; the adjective-first order only as a whole singular heading /
# alert line, since "Відкриті вакансії | Закриті вакансії" is a filter / sidebar on open job pages) AND that frame has
# no visible fillable control. Tab lists (the outline's "tabs ..." entries) are navigation, never read. A form page with a "this position is
# closed" line in its footer stays silent: the control test is Engine::BuildFieldInventory.control?, the one definition
# of "fillable", filled or not (the gate also runs after the last fill, right before submit). The one exception is a
# LONE filled select / combobox (a language switcher on the closed page): site chrome, not a form to apply with.
# -> Halt(:closed_posting, detail: the matched text).
class Apply::Gate::ClosedPosting < Apply::Gate::Base
  CLOSED_LEXICON = Regexp.union(
    /no longer accepting applications/i,
    /no longer accepting (applications|candidates|resumes)/i,
    /(job|position|posting|role|vacancy) (is )?no longer (available|open|active)/i,
    /(job|position|posting|role|vacancy) has been (closed|filled)/i,
    /(position|vacancy|posting) (is )?closed/i,
    /вакансі\p{L}* (закрит|більше не (доступн|актуальн)|неактивн)/i,
    /(^|(?<=^h\d ))закрит(а|у) вакансі[яю](?=[.!]?$)/i,
    /ваканси\p{L}* (закрыт|больше не (доступн|актуальн)|неактивн)/i,
    /(^|(?<=^h\d ))закрыт(ая|ую) ваканси[яю](?=[.!]?$)/i,
    /набір закрито/i,
    /набор закрыт/i,
    /прийом (заявок|резюме|відгуків) (закрит|завершен)/i,
    /при[её]м (заявок|резюме|откликов) (закрыт|завершен)/i
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
    headings = Array(frame['outline']).reject { |line| line.start_with?('tabs ') }
    text = (headings + Array(frame['alerts'])).join("\n")
    text[CLOSED_LEXICON]
  end

  def fillable?(snapshot, frame)
    controls = snapshot.elements.select do |element|
      element['frame'] == frame['ref'] && element['visible'] && Apply::Operation::Engine::BuildFieldInventory.control?(element)
    end
    controls.any? && !(controls.one? && switcher?(controls.first))
  end

  def switcher?(element)
    (element['tag'] == 'select' || element['group'] == 'combobox') && (element['filled'] || element['chip'].present?)
  end
end
