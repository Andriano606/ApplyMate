# frozen_string_literal: true

# Three-state operator toggle between search pills: clicking cycles
# і → або → (або) → і. The '(або)' state joins the adjacent pills into an
# explicit parenthesized OR group, overriding the default AND-binds-tighter
# precedence (see Vacancy::Operation::BuildSearchQuery::OPS).
#
# No custom JS: three hidden radios hold the states; the visible label always
# shows the current state but its `for` targets the NEXT state's radio, so a
# click advances the cycle and the radio's change event triggers
# turbo-form#update.
class Vacancy::Component::SearchBar::OpToggle < ApplyMate::Component::Base
  def initialize(name:, index:, value:)
    @name  = name
    @index = index
    @value = Vacancy::Operation::BuildSearchQuery::OPS.include?(value) ? value : 'and'
    super()
  end

  private

  def radio(state, peer_class)
    radio_button_tag "#{@name}[#{@index}]", state, @value == state,
                     id: radio_id(state), class: "sr-only #{peer_class}",
                     data: { action: 'change->turbo-form#update' }
  end

  def radio_id(state)
    "#{@name}_#{@index}_#{state}"
  end

  def label_text(state)
    I18n.t("vacancy.search.#{ { 'and' => 'and', 'or' => 'or', 'g_or' => 'grouped_or' }.fetch(state) }")
  end

  def label_classes
    'items-center text-[10px] font-bold tracking-widest text-gray-400 hover:text-indigo-500 ' \
      'transition-colors duration-200 select-none px-1 cursor-pointer'
  end
end
