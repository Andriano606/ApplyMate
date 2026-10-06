# frozen_string_literal: true

# The vacancy workspace: summary, description and — for signed-in users — the live applies panel, CV list
# and Q&A, each a lazy turbo-frame. Lays out as one column on phones (sidebar right after the summary) and
# as a 2/3 main column with a sticky 1/3 sidebar on lg+.
class Vacancy::Component::Show < ApplyMate::Component::Base
  # Explicit rows (auto + 1fr) so a sidebar taller than the summary never pushes the description down.
  GRID_CLASSES = 'grid grid-cols-1 gap-4 sm:gap-6 lg:grid-cols-3 lg:grid-rows-[auto_1fr]'
  SIDEBAR_CLASSES = 'min-w-0 lg:col-start-3 lg:row-span-2 lg:row-start-1 lg:sticky lg:top-20 lg:self-start'
  SUMMARY_CLASSES = 'min-w-0 rounded-xl border border-gray-200 bg-white p-4 dark:border-gray-700 ' \
                    'dark:bg-gray-800 sm:p-6 lg:col-span-2'
  # Lazy frames render after Turbo has tried to scroll to the URL fragment (/vacancies/:id#apply_<hashid>);
  # hashchange covers back/forward between the in-page apply/CV anchors.
  ANCHOR_SCROLL = {
    controller: 'anchor-scroll',
    action: 'turbo:frame-load->anchor-scroll#reveal hashchange@window->anchor-scroll#follow'
  }.freeze
  # On in-page apply <-> CV links (data-turbo=false): opens the collapsed target, also on a repeated click.
  ANCHOR_JUMP = 'click->anchor-scroll#jump'

  def initialize(vacancy:, **)
    @vacancy = vacancy
  end

  private

  def header_opts
    { title: @vacancy.title, back_link: helpers.root_path, back_text: I18n.t('vacancy.show.back') }
  end

  def added_on
    I18n.t('vacancy.show.added_on', date: I18n.l(@vacancy.created_at.to_date, format: :long))
  end
end
