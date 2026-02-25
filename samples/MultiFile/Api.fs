module Api

open Domain
open Logic

let formatTemperature (t: Temperature) scale =
  let converted = convert t scale
  sprintf "%.1f°" converted.Celsius
