class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :chat, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false, default: ""
      t.string :status, null: false, default: "pending"

      t.timestamps
    end
  end
end
