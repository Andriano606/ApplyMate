# frozen_string_literal: true

# After the submit click the site asks for an emailed verification code (design §10.4): a frame's outline / alerts
# match CODE_LEXICON AND the frame has a visible text-like input that is a code input (autocomplete=one-time-code, or
# a name / id / placeholder like code / otp / verification). Then the run parks in Engine::AwaitInput until the user
# types the code (ProvideInput) and the gate returns true; otherwise nil. A thank-you page has no such input.
# The claim already exists here: a timeout lands in submit_unverified through the claim rule.
class Apply::Gate::EmailCode < Apply::Gate::Base
  CODE_LEXICON = Regexp.union(
    /enter the (verification |security |one-time )?code/i,
    /code (we|that was) (sent|emailed)/i,
    /check your (email|inbox) for (a|the) code/i,
    /введіть код/i,
    /код підтвердження/i,
    /код из письма/i
  ).freeze
  CODE_INPUT = /code|otp|verification/i
  TEXT_TYPES = [ nil, '', 'text', 'tel', 'number', 'search' ].freeze

  def self.events
    %i[after_submit]
  end

  def call(ctx, snapshot: nil, **)
    return if snapshot.nil?

    snapshot.frames.each do |frame|
      next unless (Array(frame['outline']) + Array(frame['alerts'])).join("\n").match?(CODE_LEXICON)

      element = snapshot.elements.find { |candidate| candidate['frame'] == frame['ref'] && code_input?(candidate) }
      next unless element

      Apply::Operation::Engine::AwaitInput.call(ctx:, kind: 'email_code', field_element: element, frame:)
      return true
    end
    nil
  end

  private

  def code_input?(element)
    return false unless element['tag'] == 'input' && element['visible'] && !element['disabled'] && !element['password']
    return false unless TEXT_TYPES.include?(element['type'])

    attrs = element['attrs'] || {}
    attrs['autocomplete'] == 'one-time-code' || %w[name id placeholder].any? { |key| attrs[key].to_s.match?(CODE_INPUT) }
  end
end
