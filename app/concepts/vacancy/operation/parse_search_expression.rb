# frozen_string_literal: true

# Parses a boolean search expression into an AST of Phrase / And / Or nodes
# (result model):
#
#   Vacancy::Operation::ParseSearchExpression.call(text: 'embedded і stm32 і (remote або віддалено)').model
#   # => And[Phrase('embedded'), Phrase('stm32'), Or[Phrase('remote'), Phrase('віддалено')]]
#
# Operators (case-insensitive): і / та / and / && / & — AND; або / or / || / | — OR.
# AND binds tighter than OR; parentheses override precedence. Consecutive words
# merge into a single phrase ('Ruby on Rails'), and a quoted string is always a
# literal phrase, so operator words themselves can be searched ("і").
#
# Parsing is lenient — user input must never raise: unbalanced parens are
# auto-closed or skipped, dangling operators are ignored, and input that yields
# no terms at all falls back to a literal phrase of the whole string.
class Vacancy::Operation::ParseSearchExpression < ApplyMate::Operation::Base
  Phrase = Struct.new(:text)
  And    = Struct.new(:nodes)
  Or     = Struct.new(:nodes)

  AND_OPS = %w[і та and && &].freeze
  OR_OPS  = %w[або or || |].freeze

  TOKEN_RE = /"[^"]*"|\(|\)|[^\s()]+/

  def perform!(text:, **)
    skip_authorize

    @input  = text.to_s
    @tokens = @input.scan(TOKEN_RE)
    @pos    = 0

    self.model = parse
  end

  private

  def parse
    nodes = []
    until eof?
      before = @pos
      node = parse_or
      nodes << node if node
      advance if @pos == before # stray ')' at top level — skip it
    end

    combine(And, nodes) || (Phrase.new(@input.strip) unless @input.blank?)
  end

  def parse_or
    nodes = [ parse_and ].compact

    while classify(peek) == :or
      advance
      node = parse_and
      nodes << node if node
    end

    combine(Or, nodes)
  end

  def parse_and
    nodes = [ parse_term ].compact

    loop do
      case classify(peek)
      when :and
        advance
        node = parse_term
      when :word, :lparen # implicit AND between adjacent terms: `stm32 (remote або віддалено)`
        node = parse_term
      else
        break
      end

      nodes << node if node
    end

    combine(And, nodes)
  end

  def parse_term
    until eof?
      case classify(peek)
      when :lparen
        advance
        node = parse_or
        advance if classify(peek) == :rparen # missing ')' at EOF — auto-close
        return node if node # empty group '()' — keep scanning
      when :rparen
        return nil # closes the enclosing group
      when :and, :or
        advance # dangling operator with no left operand — ignore
      else
        return parse_phrase
      end
    end

    nil
  end

  def parse_phrase
    words = []
    words << unquote(advance) while classify(peek) == :word
    Phrase.new(words.join(' '))
  end

  def classify(token)
    return nil     if token.nil?
    return :lparen if token == '('
    return :rparen if token == ')'
    return :word   if token.start_with?('"')

    case token.downcase
    when *AND_OPS then :and
    when *OR_OPS  then :or
    else :word
    end
  end

  def combine(type, nodes)
    return nil        if nodes.empty?
    return nodes.first if nodes.one?

    type.new(nodes)
  end

  def unquote(token)
    token.start_with?('"') ? token.delete_prefix('"').delete_suffix('"') : token
  end

  def peek
    @tokens[@pos]
  end

  def advance
    @tokens[@pos].tap { @pos += 1 }
  end

  def eof?
    @pos >= @tokens.size
  end
end
