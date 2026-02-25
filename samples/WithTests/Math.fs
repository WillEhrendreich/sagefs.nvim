module Math

let add x y = x + y

let divide x y =
  if y = 0 then Error "Division by zero"
  else Ok (x / y)

let isEven n = n % 2 = 0
