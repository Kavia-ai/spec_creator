from rest_framework import viewsets, status
from rest_framework.decorators import action
from rest_framework.response import Response
from drf_yasg.utils import swagger_auto_schema
from drf_yasg import openapi

from .models import Task, Category
from .serializers import TaskSerializer, CategorySerializer, CategoryDetailSerializer


class TaskViewSet(viewsets.ModelViewSet):
    """
    API endpoint for managing tasks.
    """
    queryset = Task.objects.all()
    serializer_class = TaskSerializer
    
    @swagger_auto_schema(
        method='get',
        operation_description="Filter tasks by status",
        manual_parameters=[
            openapi.Parameter(
                'status', 
                openapi.IN_QUERY, 
                description="Task status (pending, in_progress, completed)", 
                type=openapi.TYPE_STRING
            )
        ]
    )
    @action(detail=False, methods=['get'])
    def by_status(self, request):
        """Filter tasks by status."""
        status_param = request.query_params.get('status')
        if not status_param:
            return Response(
                {"error": "Status parameter is required."}, 
                status=status.HTTP_400_BAD_REQUEST
            )
        
        tasks = self.queryset.filter(status=status_param)
        serializer = self.serializer_class(tasks, many=True)
        return Response(serializer.data)


class CategoryViewSet(viewsets.ModelViewSet):
    """
    API endpoint for managing categories.
    """
    queryset = Category.objects.all()
    serializer_class = CategorySerializer
    
    def get_serializer_class(self):
        """Return appropriate serializer class."""
        if self.action == 'retrieve':
            return CategoryDetailSerializer
        return CategorySerializer
    
    @swagger_auto_schema(
        method='post',
        operation_description="Add tasks to a category",
        request_body=openapi.Schema(
            type=openapi.TYPE_OBJECT,
            required=['task_ids'],
            properties={
                'task_ids': openapi.Schema(
                    type=openapi.TYPE_ARRAY,
                    items=openapi.Schema(type=openapi.TYPE_INTEGER)
                )
            }
        )
    )
    @action(detail=True, methods=['post'])
    def add_tasks(self, request, pk=None):
        """Add tasks to a category."""
        try:
            category = self.get_object()
            task_ids = request.data.get('task_ids', [])
            
            if not task_ids:
                return Response(
                    {"error": "task_ids parameter is required."}, 
                    status=status.HTTP_400_BAD_REQUEST
                )
            
            tasks = Task.objects.filter(id__in=task_ids)
            category.tasks.add(*tasks)
            
            return Response(
                {"message": f"Added {tasks.count()} tasks to category."},
                status=status.HTTP_200_OK
            )
        except Exception as e:
            return Response(
                {"error": str(e)}, 
                status=status.HTTP_400_BAD_REQUEST
            ) 