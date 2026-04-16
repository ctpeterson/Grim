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

    // Accept Grid expression templates (LatticeBinaryExpression, etc.)
    template<typename Expr,
             typename = std::enable_if_t<!std::is_same<std::decay_t<Expr>, Field>::value &&
                                         !std::is_same<std::decay_t<Expr>, T>::value &&
                                         !std::is_pointer<std::decay_t<Expr>>::value>>
    Field(Expr&& expr): _p(std::make_shared<T>(std::forward<Expr>(expr))) {}

    T& operator*() { return *_p; }
    const T& operator*() const { return *_p; }
    T* operator->() { return _p.get(); }
    const T* operator->() const { return _p.get(); }
};

template<typename T> struct is_field : std::false_type {};
template<typename T> struct is_field<Field<T>> : std::true_type {};

// Holder<T> — a shared_ptr wrapper for non-default-constructible C++ types
// (operators, solvers, etc.) that need reference semantics in Nim ref objects.
template<typename T>
struct Holder {
    std::shared_ptr<T> _p;

    Holder() = default;
    Holder(const Holder&) = default;
    Holder(Holder&&) = default;
    Holder& operator=(const Holder&) = default;
    Holder& operator=(Holder&&) = default;

    template<typename... Args>
    explicit Holder(Args&&... args): _p(std::make_shared<T>(std::forward<Args>(args)...)) {}

    T& operator*() { return *_p; }
    const T& operator*() const { return *_p; }
    T* operator->() { return _p.get(); }
    const T* operator->() const { return _p.get(); }
};

template<typename T> struct is_holder : std::false_type {};
template<typename T> struct is_holder<Holder<T>> : std::true_type {};

template<typename U>
decltype(auto) gd(U&& x) {
    if constexpr (is_field<typename std::decay<U>::type>::value ||
                  is_holder<typename std::decay<U>::type>::value) {
        return *x;
    } else {
        return std::forward<U>(x);
    }
}
