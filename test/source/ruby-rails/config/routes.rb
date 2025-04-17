Rails.application.routes.draw do
  # Root route
  root 'home#index'

  # Products routes
  resources :products

  # Authentication routes
  get '/login', to: 'sessions#new'
  post '/login', to: 'sessions#create'
  delete '/logout', to: 'sessions#destroy'

  # User routes
  get '/signup', to: 'users#new'
  post '/signup', to: 'users#create'

  # Static pages
  get '/about', to: 'pages#about'
  get '/contact', to: 'pages#contact'
  get '/terms', to: 'pages#terms'

  # Dashboard
  get '/dashboard', to: 'dashboard#index'

  # API routes
  namespace :api do
    namespace :v1 do
      resources :products, only: [:index, :show, :create]
      resources :users, except: [:destroy]
    end
  end

  get "errors/not_found"
  get "blog/by_date"
  get "dashboard/index"
  get "categories/index"
  get "categories/show"
  get "categories/new"
  get "categories/create"
  get "categories/edit"
  get "categories/update"
  get "categories/destroy"
  get "admin/show"
  get "pages/about"
  get "pages/contact"
  get "pages/terms"
  get "orders/index"
  get "orders/show"
  get "orders/new"
  get "orders/create"
  get "orders/edit"
  get "orders/update"
  get "orders/destroy"
  get "orders/invoice"
  get "orders/refund"
  get "orders/recent"
  get "orders/search"
  get "posts/index"
  get "posts/show"
  get "posts/new"
  get "posts/create"
  get "posts/edit"
  get "posts/update"
  get "posts/destroy"
  get "users/new"
  get "users/create"
  get "sessions/new"
  get "sessions/create"
  get "sessions/destroy"
  get "products/index"
  get "products/show"
  get "products/new"
  get "products/create"
  get "products/edit"
  get "products/update"
  get "products/destroy"
  get "home/index"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
