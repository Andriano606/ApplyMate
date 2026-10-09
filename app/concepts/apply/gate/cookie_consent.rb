# frozen_string_literal: true

# Cookie / privacy banners (design §7.3, §16): finds a visible, enabled button in the snapshot whose whole
# accessible name is a consent choice and clicks it (Session#click + settle(:click)). Prefers the least consent
# (CONSENT_LEXICON: necessary / essential only, reject / decline all, in that order); "accept all" (LAST_RESORT) only
# when the banner offers nothing else. Resolves in place and NEVER raises a Halt: a button that vanished or is
# covered (TargetNotFound / Obstructed) is traced and left to the next event.
#
# Termination: at most MAX_CLICKS clicks per browser session (Context#session= resets the count), so a banner that
# keeps coming back cannot turn every after_action into another click.
class Apply::Gate::CookieConsent < Apply::Gate::Base
  MAX_CLICKS = 2
  MAX_NAME_LENGTH = 60
  BUTTON_ROLES = %w[button link].freeze
  CONSENT_LEXICON = [
    /\A(accept|allow|use) (only )?(the )?(strictly )?(necessary|essential|required)( cookies)?( only)?\z/i,
    /\A(only|just) (strictly )?(necessary|essential|required)( cookies)?\z/i,
    /\A(reject|decline|deny|refuse)( all| optional| non-essential)?( cookies)?\z/i,
    /\A(прийняти |дозволити )?(лише |тільки )?(необхідні|обов'язкові|обов’язкові)( cookies| файли cookie| куки)?\z/i,
    /\A(відхилити|відмовитися)( все| всі| від усіх)?( cookies| файли cookie| куки)?\z/i
  ].freeze
  LAST_RESORT = [
    /\A(accept|allow|agree)( all| to all)?( cookies)?\z/i, /\A(i agree|i accept|ok|got it)\z/i,
    /\A(прийняти|дозволити|погоджуюсь|погоджуюся|згоден|зрозуміло)( все| всі)?( cookies| куки)?\z/i
  ].freeze

  def self.events
    %i[after_goto after_action]
  end

  def call(ctx, snapshot: nil, **)
    return if snapshot.nil? || !ctx.session_open? || ctx.scratch.consent_clicks >= MAX_CLICKS

    button = choose(snapshot.elements)
    return if button.nil?

    click(ctx, button)
  end

  private

  def choose(elements)
    buttons = elements.select { |element| button?(element) }
    [ *CONSENT_LEXICON, *LAST_RESORT ].each do |pattern|
      found = buttons.find { |element| pattern.match?(element['name'].to_s.squish) }
      return found if found
    end
    nil
  end

  def button?(element)
    BUTTON_ROLES.include?(element['role']) && element['visible'] && !element['disabled'] &&
      element['name'].present? && element['name'].length <= MAX_NAME_LENGTH
  end

  def click(ctx, button)
    ctx.scratch.consent_clicks += 1
    ctx.session.click(button['target'])
    ctx.session.settle(:click)
    ctx.trace(:cookie_consent, button: button['name'])
    true
  rescue ApplyMate::Client::Browser::TargetNotFound, ApplyMate::Client::Browser::Obstructed => e
    ctx.trace(:cookie_consent_failed, button: button['name'], error: e.class.name)
    nil
  end
end
