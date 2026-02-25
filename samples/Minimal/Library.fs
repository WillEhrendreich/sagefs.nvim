module Library

let add x y = x + y
let greet name = sprintf "Hello, %s!" name
let factorial n =
  let rec go acc = function
    | 0 -> acc
    | n -> go (acc * n) (n - 1)
  go 1 n
