class Organisation
  include Mongoid::Document
  include Mongoid::Timestamps::Created

  field :name

  has_many :groups, as: :something
  has_one :address
  
end
