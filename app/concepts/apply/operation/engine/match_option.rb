# frozen_string_literal: true

# The ONE answer <-> option implementation (design §7.2): which of `candidates` is the option `wanted` names. The
# answer resolver, the widgets' read-back and the review form all go through it, so "what counts as the same option"
# cannot drift. Candidates are option hashes ({ 'label' =>, 'value' => }) or plain strings; model = the best candidate
# as given, or nil. In order:
#   1. exact: normalized label (then value) equals the normalized wanted text
#   2. boolean synonyms: yes / true / 1 / так / да against no / false / 0 / ні / нет, on a label or a value
#   3. containment on word boundaries (the candidate contains the wanted text or the other way round)
#   4. token overlap: Jaccard >= OVERLAP_THRESHOLD
# Steps 2-4 answer only when exactly one candidate (step 4: one best candidate) qualifies; ambiguity is nil, never a
# guess.
class Apply::Operation::Engine::MatchOption < ApplyMate::Operation::Base
  OVERLAP_THRESHOLD = 0.6
  TRUE_WORDS = %w[yes true 1 y так да].freeze
  FALSE_WORDS = %w[no false 0 n ні нет].freeze
  Entry = Struct.new(:candidate, :label, :value)

  # Does the displayed option text (or value) name `wanted`? Same rules as the resolver.
  def self.same?(displayed, wanted)
    !call(candidates: [ displayed ], wanted:).model.nil?
  end

  def self.truthy?(text)
    TRUE_WORDS.include?(normalize(text))
  end

  def self.falsy?(text)
    FALSE_WORDS.include?(normalize(text))
  end

  def self.normalize(text)
    text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^\p{L}\p{N}]+/, ' ').squish
  end

  def perform!(candidates:, wanted:, **)
    skip_authorize
    wanted_text = self.class.normalize(wanted)
    entries = Array(candidates).map { |candidate| Entry.new(candidate, *texts_of(candidate)) }
    self.model = wanted_text.empty? ? nil : best(entries, wanted_text)&.candidate
  end

  private

  def texts_of(candidate)
    return [ self.class.normalize(candidate['label']), self.class.normalize(candidate['value']) ] if candidate.respond_to?(:key?)

    [ self.class.normalize(candidate), nil ]
  end

  def best(entries, wanted)
    exact(entries, wanted) || boolean(entries, wanted) || containing(entries, wanted) || overlapping(entries, wanted)
  end

  def exact(entries, wanted)
    entries.find { |entry| entry.label == wanted } || entries.find { |entry| entry.value == wanted }
  end

  def boolean(entries, wanted)
    words = [ TRUE_WORDS, FALSE_WORDS ].find { |list| list.include?(wanted) }
    return unless words

    only(entries.select { |entry| [ entry.label, entry.value ].any? { |text| words.include?(text) } })
  end

  def containing(entries, wanted)
    only(entries.select { |entry| entry.label.present? && (within?(entry.label, wanted) || within?(wanted, entry.label)) })
  end

  def within?(inner, outer)
    " #{outer} ".include?(" #{inner} ")
  end

  def overlapping(entries, wanted)
    wanted_tokens = wanted.split
    scored = entries.map { |entry| [ entry, jaccard(entry.label.split, wanted_tokens) ] }
    top = scored.map(&:last).max
    return if top.nil? || top < OVERLAP_THRESHOLD

    only(scored.select { |_entry, score| score == top }.map(&:first))
  end

  def jaccard(left, right)
    union = (left | right).size
    union.zero? ? 0.0 : (left & right).size.to_f / union
  end

  def only(entries)
    entries.first if entries.one?
  end
end
