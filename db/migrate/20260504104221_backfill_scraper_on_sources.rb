# frozen_string_literal: true

class BackfillScraperOnSources < ActiveRecord::Migration[8.1]
  def up
    Source.where(name: 'Dou').update_all(scraper: 'ApplyMate::Scraper::Dou')
    Source.where(name: 'Djinni').update_all(scraper: 'ApplyMate::Scraper::Djinni')
  end

  def down
    Source.update_all(scraper: nil)
  end
end
