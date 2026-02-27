namespace NestedModules

module Outer =
  let outerValue = 42

  module Inner =
    let innerValue = 7

    let innerFunction x = x + innerValue

  let useInner = Inner.innerFunction 10

module Standalone =
  open System

  type Status =
    | Active
    | Inactive

  let isActive status =
    match status with
    | Active -> true
    | Inactive -> false

  let toggle status =
    match status with
    | Active -> Inactive
    | Inactive -> Active
