Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  resources :posts
  resources :chats do
    resources :messages, only: [ :create ]
  end
  root "chats#index"
end
