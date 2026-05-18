class CreateChats < ActiveRecord::Migration[8.1]
  def change
    create_table :chats do |t|
      t.string :title, null: false, default: "New Chat"

      t.timestamps
    end
  end
end
