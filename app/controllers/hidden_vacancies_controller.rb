class HiddenVacanciesController < ApplicationController
  def create
    endpoint HiddenVacancy::Operation::Create do |m|
      m.success { |result| render_card(result.model.vacancy, hidden: true) }
    end
  end

  def destroy
    endpoint HiddenVacancy::Operation::Destroy do |m|
      m.success { |result| render_card(result.model.vacancy, hidden: false) }
    end
  end

  private

  # Both actions swap the card in place: hiding blurs it, restoring brings it back.
  def render_card(vacancy, hidden:)
    html = render_to_string(Vacancy::Component::Card.new(vacancy:, hidden:), layout: false)
    render turbo_stream: turbo_stream.replace(helpers.dom_id(vacancy), html:, method: :morph)
  end
end
