/*
  Grim: https://github.com/ctpeterson/Grim

  Field<T> — a thin shared_ptr wrapper that gives Grid lattice types
  default constructors and reference semantics while remaining
  transparent to the importcpp FFI layer.

  MIT License — Copyright (c) 2026 Grim
*/

#pragma once

#include <memory>
#include <type_traits>
#include <Grid/Grid.h>

template<typename T>
struct Field {
    std::shared_ptr<T> _p;

    Field() = default;
    Field(const Field&) = default;
    Field(Field&&) = default;
    Field& operator=(const Field&) = default;
    Field& operator=(Field&&) = default;

    explicit Field(Grid::GridBase* g): _p(std::make_shared<T>(g)) {}
    Field(const T& val): _p(std::make_shared<T>(val)) {}
    Field(T&& val): _p(std::make_shared<T>(std::move(val))) {}

    T& operator*() { return *_p; }
    const T& operator*() const { return *_p; }
    T* operator->() { return _p.get(); }
    const T* operator->() const { return _p.get(); }
};

template<typename T> struct is_field : std::false_type {};
template<typename T> struct is_field<Field<T>> : std::true_type {};

template<typename U>
decltype(auto) gd(U&& x) {
    if constexpr (is_field<typename std::decay<U>::type>::value) {
        return *x;
    } else {
        return std::forward<U>(x);
    }
}
