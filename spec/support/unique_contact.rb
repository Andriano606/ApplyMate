# frozen_string_literal: true

# Test emails and phone numbers must differ on every use: never repeat one hardcoded value across specs, fixtures or
# runs (a shared literal hides specs that only pass because two unrelated records carry the same contact).
module UniqueContact
  def unique_email(prefix = 'user')
    "#{prefix}-#{SecureRandom.hex(4)}@example.com"
  end

  # Ukrainian mobile format, +380 and nine random digits.
  def unique_phone
    "+380#{format('%09d', SecureRandom.random_number(1_000_000_000))}"
  end
end
