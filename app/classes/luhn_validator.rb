# frozen_string_literal: true

module LuhnValidator
  def self.valid?(number)
    digits = number.to_s.gsub(/\D/, '').chars.map(&:to_i)
    return false if digits.empty?

    check_digit = digits.pop

    sum = digits.reverse.each_with_index.map do |d, i|
      d *= 2 if i.even?
      d > 9 ? d - 9 : d
    end.sum

    (sum + check_digit) % 10 == 0
  end
end
