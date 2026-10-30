class ArticlePolicy < ApplicationPolicy
  def show?
    record.published? || update?
  end

  def create?
    user.editor? || user.admin?
  end

  def update?
    user.admin? || record.author == user
  end

  def publish?
    user.admin?
  end
end
