# frozen_string_literal: true

class Source < ApplicationRecord
  CLIENTS = %w[ApplyMate::Client::Browser ApplyMate::Client::Http].freeze

  has_one_attached :logo
  has_many :vacancies, dependent: :destroy
  has_many :source_profiles, dependent: :destroy

  validates :name, presence: true
  validates :base_url, presence: true
  validates :logo, presence: true
  validates :client, presence: true, inclusion: { in: CLIENTS.map(&:to_s) }

  jsonb_accessor :selectors,
                 job_list_selector: :string

  jsonb_accessor :urls,
                 job_list_url: :string
end
