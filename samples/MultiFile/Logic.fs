module Logic

open Domain

let toFahrenheit (t: Temperature) =
  { Celsius = t.Celsius * 9.0 / 5.0 + 32.0 }

let toKelvin (t: Temperature) =
  { Celsius = t.Celsius + 273.15 }

let convert (t: Temperature) scale =
  match scale with
  | Celsius -> t
  | Fahrenheit -> toFahrenheit t
  | Kelvin -> toKelvin t
