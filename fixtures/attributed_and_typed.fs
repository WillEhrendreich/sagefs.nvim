module AttributedAndTyped

open System

[<Literal>]
let MaxRetries = 5

[<Obsolete("Use newFunction instead")>]
let oldFunction x = x + 1

type Config = {
  Host: string
  Port: int
  Timeout: TimeSpan
}

type Status =
  | Active
  | Inactive
  | Pending of reason: string

let rec isEven n = if n = 0 then true else isOdd (n - 1)
and isOdd n = if n = 0 then false else isEven (n - 1)

type IValidator<'T> =
  abstract Validate: 'T -> bool

let defaultConfig = {
  Host = "localhost"
  Port = 8080
  Timeout = TimeSpan.FromSeconds 30.0
}

