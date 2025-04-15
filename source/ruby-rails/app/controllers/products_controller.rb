class ProductsController < ApplicationController
  # Mock data
  PRODUCTS = [
    { id: 1, name: "Laptop", price: 999.99, category: "Electronics", in_stock: true },
    { id: 2, name: "Smartphone", price: 699.99, category: "Electronics", in_stock: true },
    { id: 3, name: "Headphones", price: 149.99, category: "Electronics", in_stock: false },
    { id: 4, name: "Coffee Maker", price: 79.99, category: "Kitchen", in_stock: true },
    { id: 5, name: "Desk Chair", price: 199.99, category: "Furniture", in_stock: true }
  ]

  # GET /products
  def index
    # Query parameters example
    @category = params[:category]
    @min_price = params[:min_price]
    @max_price = params[:max_price]
    @in_stock = params[:in_stock]

    @products = PRODUCTS.dup

    # Filter by category if provided
    @products = @products.select { |p| p[:category] == @category } if @category.present?

    # Filter by price range if provided
    if @min_price.present? && @max_price.present?
      @products = @products.select { |p| p[:price].between?(@min_price.to_f, @max_price.to_f) }
    end

    # Filter by stock status if provided
    if @in_stock.present?
      @products = @products.select { |p| p[:in_stock] == (@in_stock == "true") }
    end

    # Sort by price (asc/desc)
    @sort = params[:sort]
    if @sort == "price_asc"
      @products = @products.sort_by { |p| p[:price] }
    elsif @sort == "price_desc"
      @products = @products.sort_by { |p| -p[:price] }
    end

    # Pagination example
    @page = (params[:page] || 1).to_i
    @per_page = (params[:per_page] || 2).to_i
    @total_pages = (@products.size.to_f / @per_page).ceil
    @products = @products[(@page - 1) * @per_page, @per_page] || []

    # Response format based on format parameter
    respond_to do |format|
      format.html # index.html.erb
      format.json { render json: @products }
      format.xml { render xml: @products }
    end
  end

  # GET /products/:id
  def show
    @product = PRODUCTS.find { |p| p[:id] == params[:id].to_i }
    
    if @product
      respond_to do |format|
        format.html # show.html.erb
        format.json { render json: @product }
      end
    else
      flash[:error] = "Product not found"
      redirect_to products_path
    end
  end

  # GET /products/new
  def new
    @product = { id: nil, name: "", price: 0.0, category: "", in_stock: true }
  end

  # POST /products
  def create
    # Create new product from params
    new_product = {
      id: PRODUCTS.last[:id] + 1,
      name: params[:name],
      price: params[:price].to_f,
      category: params[:category],
      in_stock: params[:in_stock] == "true"
    }

    # Add to mock data
    PRODUCTS << new_product

    respond_to do |format|
      format.html { redirect_to products_path, notice: "Product was successfully created." }
      format.json { render json: new_product, status: :created }
    end
  end

  # GET /products/:id/edit
  def edit
    @product = PRODUCTS.find { |p| p[:id] == params[:id].to_i }
    
    unless @product
      flash[:error] = "Product not found"
      redirect_to products_path
    end
  end

  # PATCH/PUT /products/:id
  def update
    product = PRODUCTS.find { |p| p[:id] == params[:id].to_i }
    
    if product
      # Update product attributes
      product[:name] = params[:name] if params[:name].present?
      product[:price] = params[:price].to_f if params[:price].present?
      product[:category] = params[:category] if params[:category].present?
      product[:in_stock] = params[:in_stock] == "true" if params[:in_stock].present?

      respond_to do |format|
        format.html { redirect_to product_path(product[:id]), notice: "Product was successfully updated." }
        format.json { render json: product }
      end
    else
      flash[:error] = "Product not found"
      redirect_to products_path
    end
  end

  # DELETE /products/:id
  def destroy
    product_index = PRODUCTS.find_index { |p| p[:id] == params[:id].to_i }
    
    if product_index
      PRODUCTS.delete_at(product_index)
      respond_to do |format|
        format.html { redirect_to products_path, notice: "Product was successfully deleted." }
        format.json { head :no_content }
      end
    else
      flash[:error] = "Product not found"
      redirect_to products_path
    end
  end
end
