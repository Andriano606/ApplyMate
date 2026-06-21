# frozen_string_literal: true

class ChangeProxiesUniqueIndexToIncludeProtocol < ActiveRecord::Migration[8.1]
  def change
    remove_index :proxies, column: %i[host port], unique: true, name: "index_proxies_on_host_and_port"
    add_index :proxies, %i[host port protocol], unique: true, name: "index_proxies_on_host_and_port_and_protocol"
  end
end
