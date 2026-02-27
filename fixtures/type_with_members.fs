module TypeWithMembers

type Point = {
  X: float
  Y: float
}
with
  member this.Distance =
    sqrt (this.X * this.X + this.Y * this.Y)
  member this.Translate dx dy =
    { X = this.X + dx; Y = this.Y + dy }

let origin = { X = 0.0; Y = 0.0 }

type Color =
  | Red
  | Green
  | Blue
with
  member this.ToHex =
    match this with
    | Red -> "#FF0000"
    | Green -> "#00FF00"
    | Blue -> "#0000FF"

let defaultColor = Red
