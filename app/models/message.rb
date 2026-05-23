class Message < ApplicationRecord
  belongs_to :chat

  ROLES = %w[ user assistant ].freeze
  STATUSES = %w[ pending complete error ].freeze

  attribute :status, :string, default: "pending"

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :content, presence: true, unless: -> { status == "pending" }
end
