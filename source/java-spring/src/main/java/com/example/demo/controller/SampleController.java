package com.example.demo.controller;

import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api")
public class SampleController {

    @GetMapping("/hello")
    public String hello() {
        return "Hello, Spring Boot!";
    }

    @GetMapping("/users/{id}")
    public String getUser(@PathVariable Long id) {
        return "User with ID: " + id;
    }

    @PostMapping("/users")
    public String createUser(@RequestBody String userData) {
        return "User created with data: " + userData;
    }

    @PutMapping("/users/{id}")
    public String updateUser(@PathVariable Long id, @RequestBody String userData) {
        return "User with ID " + id + " updated with data: " + userData;
    }

    @DeleteMapping("/users/{id}")
    public String deleteUser(@PathVariable Long id) {
        return "User with ID " + id + " deleted";
    }
} 