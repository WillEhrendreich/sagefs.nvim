module Pong 
  // All coordinates normalized 0.0–1.0
  // Pure functions — every one is a hot-reload target

type State =
  { BallX: float; BallY: float
    BallVX: float; BallVY: float
    LeftY: float; RightY: float
    LeftScore: int; RightScore: int
    Trail: (float * float) list }

let init () =
  { BallX = 0.5; BallY = 0.5
    BallVX = 0.6; BallVY = 0.4
    LeftY = 0.5; RightY = 0.5
    LeftScore = 0; RightScore = 0
    Trail = [] }

let ballColor () = (255, 255, 255)
let paddleColor () = (255, 255, 255)
let bgColor () = (0, 0, 0)
let trailColor (i: int) = (80, 80, 80)

let paddleHeight () = 0.15
let paddleWidth () = 0.02
let ballSize () = 0.02
let maxTrail () = 0

let update (dt: float) (state: State) =
  let aiSpeed = 1.0
  let moveToward (current: float) (target: float) =
    let diff = target - current
    let maxMove = aiSpeed * dt
    if abs diff < maxMove then target
    else current + (if diff > 0.0 then maxMove else -maxMove)

  let leftY = moveToward state.LeftY state.BallY
  let rightY = moveToward state.RightY state.BallY

  let bx = state.BallX + state.BallVX * dt
  let by = state.BallY + state.BallVY * dt

  // Wall bounce (top/bottom)
  let by, vy =
    if by < 0.0 then abs by, abs state.BallVY
    elif by > 1.0 then 2.0 - by, -(abs state.BallVY)
    else by, state.BallVY

  // Paddle collision + scoring
  let paddleX = 0.04
  let bx, vx, vy, ls, rs =
    if bx < paddleX then
      if abs (by - leftY) < paddleHeight () then
        let reflect = (by - leftY) / (paddleHeight ())
        2.0 * paddleX - bx, abs state.BallVX * 1.05, vy + reflect * 0.3,
          state.LeftScore, state.RightScore
      else
        0.5, 0.6, 0.4, state.LeftScore, state.RightScore + 1
    elif bx > (1.0 - paddleX) then
      if abs (by - rightY) < paddleHeight () then
        let reflect = (by - rightY) / (paddleHeight ())
        2.0 * (1.0 - paddleX) - bx, -(abs state.BallVX) * 1.05, vy + reflect * 0.3,
          state.LeftScore, state.RightScore
      else
        0.5, -0.6, -0.4, state.LeftScore + 1, state.RightScore
    else
      bx, state.BallVX, vy, state.LeftScore, state.RightScore

  // Clamp ball speed
  let maxSpeed = 2.0
  let vx = max -maxSpeed (min maxSpeed vx)
  let vy = max -maxSpeed (min maxSpeed vy)

  let trail =
    if maxTrail () > 0 then
      (state.BallX, state.BallY) :: state.Trail |> List.truncate (maxTrail ())
    else []

  { BallX = bx; BallY = by
    BallVX = vx; BallVY = vy
    LeftY = leftY; RightY = rightY
    LeftScore = ls; RightScore = rs
    Trail = trail }

let toHtml (state: State) =
  let w, h = 600, 400
  let px (nx: float) = int (nx * float w)
  let py (ny: float) = int (ny * float h)
  let br, bg, bb = bgColor ()
  let pr, pg, pb = paddleColor ()
  let ar, ag, ab = ballColor ()
  let pw = max 1 (px (paddleWidth ()))
  let ph = max 1 (py (paddleHeight () * 2.0))
  let bs = max 1 (px (ballSize ()))

  let trailHtml =
    state.Trail
    |> List.mapi (fun i (tx, ty) ->
      let tr, tg, tb = trailColor i
      sprintf
        "<div style='position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:rgb(%d,%d,%d);border-radius:50%%'></div>"
        (px tx - bs/2) (py ty - bs/2) bs bs tr tg tb)
    |> String.concat ""

  sprintf
    "<div style='position:relative;width:%dpx;height:%dpx;background:rgb(%d,%d,%d);margin:auto;border:2px solid #333;overflow:hidden;font-family:monospace'>\
      <div style='position:absolute;top:8px;width:100%%;text-align:center;color:#555;font-size:48px'>%d &nbsp; %d</div>\
      <div style='position:absolute;left:50%%;top:0;width:2px;height:100%%;background:#333'></div>\
      %s\
      <div style='position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:rgb(%d,%d,%d);border-radius:2px'></div>\
      <div style='position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:rgb(%d,%d,%d);border-radius:2px'></div>\
      <div style='position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:rgb(%d,%d,%d);border-radius:50%%'></div>\
      </div>"
    w h br bg bb
    state.LeftScore state.RightScore
    trailHtml
    (px 0.02) (py state.LeftY - ph/2) pw ph pr pg pb
    (px 0.96) (py state.RightY - ph/2) pw ph pr pg pb
    (px state.BallX - bs/2) (py state.BallY - bs/2) bs bs ar ag ab
