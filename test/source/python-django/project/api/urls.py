from django.urls import path, include
from rest_framework.routers import DefaultRouter
from .views import TaskViewSet, CategoryViewSet

# Create a router and register viewsets
router = DefaultRouter()
router.register(r'tasks', TaskViewSet)
router.register(r'categories', CategoryViewSet)

# URL patterns for the API
urlpatterns = [
    path('', include(router.urls)),
] 