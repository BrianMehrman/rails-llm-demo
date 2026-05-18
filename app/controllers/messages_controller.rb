class MessagesController < ApplicationController
  def create
    @chat = Chat.find(params[:chat_id])
    @chat.messages.create!(role: "user", content: params[:content], status: "complete")
    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")
    LlmResponseJob.perform_later(@chat.id, assistant_msg.id)
    redirect_to @chat
  rescue ActiveRecord::RecordInvalid
    redirect_to @chat, alert: "Message can't be blank."
  end
end
