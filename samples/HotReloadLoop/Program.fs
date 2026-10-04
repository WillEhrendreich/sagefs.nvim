module Program

open System.Threading

[<EntryPoint>]
let main _ =
  while true do
    printfn "%s" (Logic.greet ())
    Thread.Sleep 500
  0
