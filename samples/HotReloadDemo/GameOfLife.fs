module GameOfLife

open System

type Grid = byte[,]

let randomGrid width height density =
  Array2D.init width height (fun _ _ ->
    if Random.Shared.NextDouble() < density then 1uy else 0uy)

let countNeighbors (grid: Grid) x y =
  let w = Array2D.length1 grid
  let h = Array2D.length2 grid
  let mutable count = 0
  for dx in -1 .. 1 do
    for dy in -1 .. 1 do
      if dx <> 0 || dy <> 0 then
        let nx = (x + dx + w) % w
        let ny = (y + dy + h) % h
        if grid.[nx, ny] > 0uy then count <- count + 1
  count

/// Classic Conway: survive with 2-3 neighbors, born with exactly 3
let step (grid: Grid) =
  let w = Array2D.length1 grid
  let h = Array2D.length2 grid
  Array2D.init w h (fun x y ->
    let n = countNeighbors grid x y
    let age = grid.[x, y]
    if age > 0uy then
      if n = 2 || n = 3 then
        if age < 255uy then age + 1uy else 255uy
      else 0uy
    else
      if n = 3 then 1uy else 0uy)

/// Green-to-red aging: newborn = green, ancient = red
let ageColor (age: byte) =
  let a = int age
  if a <= 1 then (0uy, 255uy, 0uy)
  elif a <= 5 then (128uy, 255uy, 0uy)
  elif a <= 15 then (255uy, 255uy, 0uy)
  elif a <= 40 then (255uy, 165uy, 0uy)
  else (255uy, 50uy, 20uy)

let toHtml (grid: Grid) =
  let w = Array2D.length1 grid
  let h = Array2D.length2 grid
  let sb = Text.StringBuilder()
  sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'>") |> ignore
  sb.Append("<title>Game of Life</title>") |> ignore
  sb.Append("<style>") |> ignore
  sb.Append("body{margin:0;background:#111;display:flex;justify-content:center;align-items:center;min-height:100vh}") |> ignore
  sb.Append("table{border-collapse:collapse}") |> ignore
  sb.Append("td{width:6px;height:6px;padding:0}") |> ignore
  sb.Append("</style></head><body><table>") |> ignore
  for y in 0 .. h - 1 do
    sb.Append("<tr>") |> ignore
    for x in 0 .. w - 1 do
      let age = grid.[x, y]
      if age > 0uy then
        let r, g, b = ageColor age
        sb.Append(sprintf "<td style='background:rgb(%d,%d,%d)'></td>" r g b) |> ignore
      else
        sb.Append("<td></td>") |> ignore
    sb.Append("</tr>") |> ignore
  sb.Append("</table></body></html>") |> ignore
  sb.ToString()
