#!/usr/bin/env dotnet fsi
#r "nuget: Raylib-cs, 7.0.2"
#r "nuget: System.Text.Json"

open Raylib_cs
open System
open System.Net.Http
open System.Text.Json

let client = new HttpClient()
let mutable bx, by = 0.5f, 0.5f
let mutable lx, rx = 0.5f, 0.5f
let mutable ls, rs = 0, 0
let mutable bc = Color(255uy, 255uy, 255uy, 255uy)
let mutable pc = Color(255uy, 255uy, 255uy, 255uy)
let mutable bg = Color(0uy, 0uy, 0uy, 255uy)
let mutable bs = 0.02f
let mutable pw = 0.015f
let mutable ph = 0.15f

let fetchState () =
  try
    let json = client.GetStringAsync("http://localhost:5559/state").Result
    let doc = JsonDocument.Parse(json)
    let r = doc.RootElement
    bx <- r.GetProperty("bx").GetSingle()
    by <- r.GetProperty("by").GetSingle()
    lx <- r.GetProperty("lx").GetSingle()
    rx <- r.GetProperty("rx").GetSingle()
    ls <- r.GetProperty("ls").GetInt32()
    rs <- r.GetProperty("rs").GetInt32()
    let arr name = 
      let a = r.GetProperty(name)
      a.[0].GetByte(), a.[1].GetByte(), a.[2].GetByte()
    let r1,g1,b1 = arr "bc"
    bc <- Color(r1, g1, b1, 255uy)
    let r2,g2,b2 = arr "pc"
    pc <- Color(r2, g2, b2, 255uy)
    let r3,g3,b3 = arr "bg"
    bg <- Color(r3, g3, b3, 255uy)
    bs <- r.GetProperty("bs").GetSingle()
    pw <- r.GetProperty("pw").GetSingle()
    ph <- r.GetProperty("ph").GetSingle()
  with _ -> ()

Raylib.InitWindow(800, 500, "Pong — SageFs Hot Reload Demo")
Raylib.SetTargetFPS(60)

while not (Convert.ToBoolean(Raylib.WindowShouldClose())) do
  fetchState()
  let w, h = 800, 500
  Raylib.BeginDrawing()
  Raylib.ClearBackground(bg)
  // Left paddle
  let pxw = int (pw * float32 w)
  let pxh = int (ph * float32 h)
  Raylib.DrawRectangle(10, int ((lx - ph/2.0f) * float32 h), pxw, pxh, pc)
  // Right paddle
  Raylib.DrawRectangle(w - 10 - pxw, int ((rx - ph/2.0f) * float32 h), pxw, pxh, pc)
  // Ball
  let radius = bs * float32 (min w h)
  Raylib.DrawCircle(int (bx * float32 w), int (by * float32 h), radius, bc)
  // Score
  let white = Color(255uy, 255uy, 255uy, 255uy)
  Raylib.DrawText(sprintf "%d" ls, w/2 - 40, 20, 30, white)
  Raylib.DrawText(sprintf "%d" rs, w/2 + 25, 20, 30, white)
  Raylib.EndDrawing()

Raylib.CloseWindow()
