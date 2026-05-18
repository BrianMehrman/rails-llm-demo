class RemoveContentDefaultFromMessages < ActiveRecord::Migration[8.1]
  def change
    change_column_default :messages, :content, from: "", to: nil
  end
end
