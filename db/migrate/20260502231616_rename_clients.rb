# frozen_string_literal: true

class RenameClients < ActiveRecord::Migration[8.1]
  def change
    Source.where(client: 'BrowserClient').update_all(client: 'ApplyMate::Client::Browser')
    Source.where(client: 'HttpClient').update_all(client: 'ApplyMate::Client::Http')
  end
end
