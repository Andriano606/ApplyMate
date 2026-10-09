# frozen_string_literal: true

# A step row is shown to whoever may see its apply (its artifacts are masked screenshots / redacted HTML).
class ApplyStepPolicy < ApplicationPolicy
  def show?
    ApplyPolicy.new(user, record.apply).show?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:apply).where(applies: { user_id: user.id })
    end
  end
end
