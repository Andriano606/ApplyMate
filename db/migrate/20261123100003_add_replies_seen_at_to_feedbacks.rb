# frozen_string_literal: true

class AddRepliesSeenAtToFeedbacks < ActiveRecord::Migration[8.1]
  def change
    # When the feedback's author last saw their thread (feedback page or MCP);
    # replies by others after it are "new" (navbar badge).
    add_column :feedbacks, :replies_seen_at, :datetime
  end
end
