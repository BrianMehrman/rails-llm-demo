require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "is valid with title and body" do
    post = Post.new(title: "Hello", body: "World")
    assert post.valid?
  end

  test "is invalid without title" do
    post = Post.new(body: "World")
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  test "is invalid without body" do
    post = Post.new(title: "Hello")
    assert_not post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end
end
