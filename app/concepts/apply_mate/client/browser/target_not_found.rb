# Locate found no strategy that matched exactly one element (zero or several matches each).
# `ambiguous?`: at least one strategy matched SEVERAL elements, so the target is too broad for this page; waiting
# for the page to render does not fix that (Operation::WaitReady stops polling on it).
class ApplyMate::Client::Browser::TargetNotFound < StandardError
  attr_reader :target

  def initialize(target, message = nil, ambiguous: false)
    @target = target
    @ambiguous = ambiguous
    super(message || default_message(target, ambiguous))
  end

  def ambiguous?
    @ambiguous
  end

  private

  def default_message(target, ambiguous)
    problem = ambiguous ? 'several elements match and no strategy matched exactly one' : 'no strategy matched exactly one element'
    "#{problem}: #{target.strategies.to_json.truncate(300)}"
  end
end
