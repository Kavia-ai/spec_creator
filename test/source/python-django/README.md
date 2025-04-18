# Django REST API Sample

A sample Django REST API project with task and category management functionality.

## Features

- RESTful API using Django REST Framework
- Task and Category models with relationship
- Swagger/OpenAPI documentation
- CORS support
- Comprehensive serializers and viewsets

## API Endpoints

- `/api/tasks/` - CRUD operations for tasks
- `/api/tasks/by_status/` - Filter tasks by status
- `/api/categories/` - CRUD operations for categories
- `/api/categories/{id}/add_tasks/` - Add tasks to a category
- `/swagger/` - Swagger UI documentation
- `/redoc/` - ReDoc documentation

## Installation

1. Clone the repository
2. Install dependencies:
```
pip install -r requirements.txt
```
3. Run migrations:
```
python project/manage.py migrate
```
4. Create a superuser (optional):
```
python project/manage.py createsuperuser
```
5. Run the development server:
```
python project/manage.py runserver
```

## API Documentation

Access the Swagger documentation at:
```
http://localhost:8000/swagger/
```

## Technologies Used

- Django 4.2
- Django REST Framework
- drf-yasg (Swagger/OpenAPI)
- SQLite (development) 