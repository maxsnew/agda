module Unfolding where

open import Agda.Builtin.Nat

opaque
  foo : Set₁
  foo = Set

opaque unfolding (foo) where
  -- Unfolds bar
  bar : foo
  bar = Nat

opaque unfolding (bar) where
  -- Unfolds foo and bar
  ty : Set
  ty = bar

  quux : ty
  quux = zero