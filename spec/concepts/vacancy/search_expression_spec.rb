# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vacancy::SearchExpression do
  def phrase(text)
    described_class::Phrase.new(text)
  end

  it "parses a single word into a phrase" do
    expect(described_class.parse('rails')).to eq(phrase('rails'))
  end

  it "merges consecutive words into a single phrase" do
    expect(described_class.parse('Ruby on Rails')).to eq(phrase('Ruby on Rails'))
  end

  it "parses AND with ukrainian operator" do
    expect(described_class.parse('embedded і stm32'))
      .to eq(described_class::And.new([ phrase('embedded'), phrase('stm32') ]))
  end

  it "parses OR with ukrainian operator" do
    expect(described_class.parse('remote або віддалено'))
      .to eq(described_class::Or.new([ phrase('remote'), phrase('віддалено') ]))
  end

  it "binds AND tighter than OR" do
    expect(described_class.parse('rails або ruby і react'))
      .to eq(described_class::Or.new([
        phrase('rails'),
        described_class::And.new([ phrase('ruby'), phrase('react') ])
      ]))
  end

  it "parses the nested parenthesized expression" do
    expect(described_class.parse('(embedded і stm32 і (remote або віддалено))'))
      .to eq(described_class::And.new([
        phrase('embedded'),
        phrase('stm32'),
        described_class::Or.new([ phrase('remote'), phrase('віддалено') ])
      ]))
  end

  it "supports english and symbolic operators case-insensitively" do
    expect(described_class.parse('a AND (b OR c)'))
      .to eq(described_class.parse('a && (b || c)'))
  end

  it "treats adjacent terms as implicit AND" do
    expect(described_class.parse('stm32 (remote або віддалено)'))
      .to eq(described_class::And.new([
        phrase('stm32'),
        described_class::Or.new([ phrase('remote'), phrase('віддалено') ])
      ]))
  end

  it "keeps a quoted string as a literal phrase even if it contains operators" do
    expect(described_class.parse('"кава і чай"')).to eq(phrase('кава і чай'))
  end

  it "auto-closes a missing closing paren" do
    expect(described_class.parse('(embedded і stm32'))
      .to eq(described_class::And.new([ phrase('embedded'), phrase('stm32') ]))
  end

  it "skips a stray closing paren" do
    expect(described_class.parse('embedded і stm32)'))
      .to eq(described_class::And.new([ phrase('embedded'), phrase('stm32') ]))
  end

  it "ignores dangling operators" do
    expect(described_class.parse('або rails і')).to eq(phrase('rails'))
  end

  it "returns nil for blank input" do
    expect(described_class.parse('')).to be_nil
    expect(described_class.parse('   ')).to be_nil
  end

  it "falls back to a literal phrase when no terms can be parsed" do
    expect(described_class.parse('()')).to eq(phrase('()'))
  end
end
