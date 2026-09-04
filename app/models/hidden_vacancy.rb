# A vacancy the user looked at and dismissed. It stays in the list (rendered blurred,
# with a restore button) and does not touch search results or preset counters.
# Rows are removed together with their user or vacancy (dependent: :delete_all on both sides).
class HiddenVacancy < ApplicationRecord
  belongs_to :user
  belongs_to :vacancy

  # Ids of the given vacancies that `user` hid; [] for guests.
  def self.vacancy_ids_for(user:, vacancies:)
    return [] if user.nil?

    where(user:, vacancy_id: vacancies.map(&:id)).pluck(:vacancy_id)
  end
end
