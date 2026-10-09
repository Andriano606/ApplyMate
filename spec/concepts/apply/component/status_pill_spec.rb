# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Component::StatusPill, type: :component do
  def pill(apply)
    render_inline(described_class.new(apply:))
    page.native
  end

  def spinner?(html)
    html.at_css('span.animate-spin').present?
  end

  it 'covers exactly the lifecycle states plus not_applied' do
    expect(described_class::STATE_CONFIG.keys).to match_array(Apply.states.keys.map(&:to_sym) + [ :not_applied ])
  end

  it 'offers to apply when there is no apply' do
    html = pill(nil)

    expect(html.text).to include(I18n.t('apply.new.button'))
    expect(spinner?(html)).to be(false)
  end

  it 'shows the stage of a running apply' do
    html = pill(build(:apply, :running, stage: 'fill_form'))

    expect(html.text).to include(I18n.t('apply.stage.fill_form'))
    expect(spinner?(html)).to be(true)
  end

  it 'shows the awaiting_input stage text' do
    expect(pill(build(:apply, :running, stage: 'awaiting_input')).text).to include(I18n.t('apply.stage.awaiting_input'))
  end

  it 'falls back to the state label for a running apply without a stage' do
    expect(pill(build(:apply, state: :running, stage: nil)).text).to include(I18n.t('apply.state.running'))
  end

  Apply.states.each_key do |state|
    next if state == 'running'

    in_progress = Apply::IN_PROGRESS_STATES.include?(state)

    it "labels #{state} with its state text#{in_progress ? ' and a spinner' : ' and no spinner'}" do
      html = pill(build(:apply, state:, stage: 'generate_cv'))

      expect(html.text).to include(I18n.t("apply.state.#{state}"))
      expect(spinner?(html)).to be(in_progress)
    end
  end
end
