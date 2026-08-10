class Tagging < ApplicationRecord
  self.table_name = "comments"
  belongs_to :taggable, polymorphic: true
end
