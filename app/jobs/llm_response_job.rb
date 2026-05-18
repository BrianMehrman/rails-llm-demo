class LlmResponseJob < ApplicationJob
  queue_as :default

  def perform(chat_id, assistant_message_id)
    chat = Chat.find(chat_id)
    assistant_msg = Message.find(assistant_message_id)

    history = chat.messages
                  .where(status: "complete")
                  .order(:created_at)
                  .map { |m| { role: m.role, content: m.content } }

    begin
      response = LlmClient.new.chat(history)
      assistant_msg.update!(content: response, status: "complete")
    rescue LlmClient::Error => e
      assistant_msg.update!(content: e.message, status: "error")
    end

    Turbo::StreamsChannel.broadcast_replace_to(
      chat,
      target: assistant_msg,
      partial: "chats/message",
      locals: { message: assistant_msg }
    )
  end
end
