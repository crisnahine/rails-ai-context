class N1TestController < ApplicationController
  def index
    @posts = Post.all.eager_load(:comments)
  end
end
