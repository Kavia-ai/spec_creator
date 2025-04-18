from django.db import models


class Task(models.Model):
    """
    Model representing a task in a to-do list.
    """
    STATUS_CHOICES = [
        ('pending', 'Pending'),
        ('in_progress', 'In Progress'),
        ('completed', 'Completed'),
    ]
    
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    status = models.CharField(
        max_length=20,
        choices=STATUS_CHOICES,
        default='pending'
    )
    due_date = models.DateField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    
    def __str__(self):
        return self.title
        
    class Meta:
        ordering = ['-created_at']


class Category(models.Model):
    """
    Model representing a category for tasks.
    """
    name = models.CharField(max_length=100, unique=True)
    description = models.TextField(blank=True)
    tasks = models.ManyToManyField(Task, related_name='categories', blank=True)
    
    def __str__(self):
        return self.name
        
    class Meta:
        verbose_name_plural = 'Categories' 