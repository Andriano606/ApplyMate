# frozen_string_literal: true

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get 'up' => 'rails/health#show', as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  get 'login', to: 'sessions#new', as: :login
  post 'auth/google_oauth2', to: redirect('/'), as: :google_oauth # intercepted by OmniAuth middleware
  get 'auth/:provider/callback', to: 'sessions#oauth_callback', as: :oauth_callback
  get 'auth/failure', to: 'sessions#failure', as: :oauth_failure
  delete 'logout', to: 'sessions#destroy', as: :logout

  # Admin namespace
  namespace :admin do
    root 'dashboard#index'
    resources :users, only: [ :index ]
    resource :impersonation, only: [ :create, :destroy ]
    resources :proxies, only: [ :index, :show ]
    resources :sources, only: [ :new, :create, :index, :edit, :update, :destroy ]
    resources :api_tokens, only: [ :index, :new, :create, :destroy ]
    resource :mcp, only: [ :show ], controller: 'mcp'
    mount MissionControl::Jobs::Engine, at: '/jobs'

    mount Rswag::Api::Engine => '/api-docs'
    mount Rswag::Ui::Engine => '/api-docs'
  end

  resources :vacancies, only: [ :index, :show ] do
    resource :hidden_vacancy, only: [ :create, :destroy ]
  end
  resources :saved_filters, only: [ :new, :create, :edit, :update, :destroy ]

  # Model Context Protocol server for Claude & co. (API token auth, see .ai/docs/mcp.md)
  match 'mcp', to: 'mcp#handle', via: %i[get post delete], as: :mcp

  # Defines the root path route ("/")
  root 'home#index'
end
