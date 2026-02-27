module ComplexExpressions

open System

let classify value =
  match value with
  | v when v < 0 -> "negative"
  | 0 -> "zero"
  | v when v < 10 -> "small"
  | v when v < 100 -> "medium"
  | _ -> "large"

let processAsync url =
  async {
    let! response = Async.Sleep 100
    let result = sprintf "processed %s" url
    return result
  }

let generateSequence max =
  seq {
    for i in 1..max do
      if i % 2 = 0 then
        yield i * 2
      else
        yield i
  }

let nestedMatch x y =
  match x with
  | Some a ->
    match y with
    | Some b -> a + b
    | None -> a
  | None ->
    match y with
    | Some b -> b
    | None -> 0
