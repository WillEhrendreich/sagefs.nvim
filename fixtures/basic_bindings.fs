module BasicBindings

let add x y = x + y

let multiply a b = a * b

let greeting name =
  sprintf "Hello, %s!" name

let rec factorial n =
  if n <= 1 then 1
  else n * factorial (n - 1)

type Point = { X: float; Y: float }

type Shape =
  | Circle of radius: float
  | Rectangle of width: float * height: float

let area shape =
  match shape with
  | Circle r -> System.Math.PI * r * r
  | Rectangle (w, h) -> w * h
