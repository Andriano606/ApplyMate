# frozen_string_literal: true

class Admin::JobStats::Operation::Index < ApplyMate::Operation::Base
  DAYS = 30

  def perform!(params:, **)
    skip_authorize
    self.model = SolidQueue::Job
      .where.not(finished_at: nil)
      .where(finished_at: DAYS.days.ago..)
      .group(Arel.sql('DATE(finished_at)'), :class_name)
      .select(
        Arel.sql('DATE(finished_at) AS day'),
        :class_name,
        Arel.sql('AVG(EXTRACT(EPOCH FROM (finished_at - created_at))) AS avg_seconds')
      )
      .order(Arel.sql('DATE(finished_at)'))
  end
end
