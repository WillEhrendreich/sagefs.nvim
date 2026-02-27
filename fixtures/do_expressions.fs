module DoExpressions

let greeting = "hello"

do printfn "Starting up: %s" greeting

let mutable counter = 0

do
  counter <- counter + 1
  printfn "Counter: %d" counter

let add x y = x + y

do
  let result = add 3 4
  printfn "3 + 4 = %d" result
