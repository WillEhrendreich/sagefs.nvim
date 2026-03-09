// SageFs eval demo script
open System

let greet name =
  sprintf "Hello, %s!" name

let result = greet "World"
printfn "%s" result
;;

let add x y = x + y
let sum = add 3 4
printfn "3 + 4 = %d" sum
;;

// Expecto test
open Expecto

let tests =
  testList "demo" [
    test "addition works" { Expect.equal (add 2 3) 5 "2+3=5" }
    test "greeting works" { Expect.isTrue (result.StartsWith "Hello") "starts with Hello" }
  ]
;;
