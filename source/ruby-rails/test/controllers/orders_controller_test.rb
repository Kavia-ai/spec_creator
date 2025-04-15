require "test_helper"

class OrdersControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get orders_index_url
    assert_response :success
  end

  test "should get show" do
    get orders_show_url
    assert_response :success
  end

  test "should get new" do
    get orders_new_url
    assert_response :success
  end

  test "should get create" do
    get orders_create_url
    assert_response :success
  end

  test "should get edit" do
    get orders_edit_url
    assert_response :success
  end

  test "should get update" do
    get orders_update_url
    assert_response :success
  end

  test "should get destroy" do
    get orders_destroy_url
    assert_response :success
  end

  test "should get invoice" do
    get orders_invoice_url
    assert_response :success
  end

  test "should get refund" do
    get orders_refund_url
    assert_response :success
  end

  test "should get recent" do
    get orders_recent_url
    assert_response :success
  end

  test "should get search" do
    get orders_search_url
    assert_response :success
  end
end
