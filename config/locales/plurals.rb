# frozen_string_literal: true

# CLDR plural rule for Ukrainian: 1, 21, 31… → one; 2–4, 22–24… → few; the rest → many.
{
  uk: {
    i18n: {
      plural: {
        keys: %i[one few many other],
        rule: lambda do |n|
          next :other unless n.is_a?(Integer)

          mod10 = n % 10
          mod100 = n % 100
          if mod10 == 1 && mod100 != 11
            :one
          elsif (2..4).cover?(mod10) && !(12..14).cover?(mod100)
            :few
          else
            :many
          end
        end
      }
    }
  }
}
