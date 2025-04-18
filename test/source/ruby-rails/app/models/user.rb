class User < ApplicationRecord
  # Schema Information
  # id :integer
  # name :string
  # email :string
  # created_at :datetime
  # updated_at :datetime
  
  validates :name, presence: true
  validates :email, presence: true
end 