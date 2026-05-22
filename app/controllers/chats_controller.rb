class ChatsController < ApplicationController
  before_action :set_chat, only: %i[ show destroy ]

  def index
    @chats = Chat.order(created_at: :desc)
  end

  def show
    @messages = @chat.messages.order(:created_at)
  end

  def new
    @chat = Chat.new
  end

  def create
    @chat = Chat.new(chat_params)
    if @chat.save
      redirect_to @chat, notice: "Chat started."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @chat.destroy!
    redirect_to chats_path, notice: "Chat deleted.", status: :see_other
  end

  private

  def set_chat
    @chat = Chat.find(params[:id])
  end

  def chat_params
    params.expect(chat: [ :title ])
  end
end
