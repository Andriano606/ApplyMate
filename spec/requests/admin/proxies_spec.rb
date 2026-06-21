# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Admin Proxies API', type: :request do
  path '/admin/proxies' do
    get 'List proxies' do
      tags 'Proxies'
      description 'Returns the proxies ordered by reliability, paginated.'
      produces 'application/json'
      security [ bearerAuth: [] ]
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (will_paginate)'

      let(:admin) { create(:user, :admin) }
      let(:token) { admin.api_tokens.create!.token }
      let(:Authorization) { "Bearer #{token}" }

      response '200', 'proxies listed' do
        schema type: :object,
               required: %w[data pagination],
               properties: {
                 data: {
                   type: :array,
                   items: {
                     type: :object,
                     properties: {
                       id: { type: :string },
                       source: { type: :string },
                       protocol: { type: :string },
                       host: { type: :string },
                       port: { type: :integer },
                       url: { type: :string },
                       success_count: { type: :integer },
                       fail_count: { type: :integer },
                       reliability: { type: :number },
                       failed_at: { type: :string, nullable: true },
                       created_at: { type: :string },
                       updated_at: { type: :string }
                     }
                   }
                 },
                 pagination: {
                   type: :object,
                   properties: {
                     current_page: { type: :integer },
                     total_pages: { type: :integer },
                     total_entries: { type: :integer },
                     next_page: { type: :integer, nullable: true }
                   }
                 }
               }

        before do
          source = create(:source)
          create_list(:proxy, 2).each { |proxy| create(:proxy_source_stat, proxy: proxy, source: source) }
        end

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['data'].size).to eq(2)
          expect(body['pagination']['total_entries']).to eq(2)
        end
      end

      response '403', 'token does not belong to an admin' do
        let(:token) { create(:user).api_tokens.create!.token }

        run_test!
      end
    end
  end
end
