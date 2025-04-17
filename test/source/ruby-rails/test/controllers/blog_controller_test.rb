require "test_helper"

class BlogControllerTest < ActionDispatch::IntegrationTest
  test "should get by_date" do
    get blog_by_date_url
    assert_response :success
  end
end
