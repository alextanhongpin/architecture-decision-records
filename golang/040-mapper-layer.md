# Mapper Layer

## Status 

`draft`

## Context

An understanding of [code organisation](https://go.dev/doc/code) is necessary to understand the problem.

Imagine we have two separate layers, A and B that are defined as separate packages.

When package A wants to call package B, then package A has to import package B. This couples both packages, forming a gradient instead of a cleanly separated layer.

This is especially common in layered architecture.

## Decisions

Introduce another intermediary layer that has knowledge about both package.

This package will not be imported directly from package A. 

It will be injected through dependency injection.

Package A only knows the interface for the methods to be called.

Although this package knows the types of both package A and B, only types from package A will be returned.

