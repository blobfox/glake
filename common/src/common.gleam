
import gleam/json

import gleam/list
import gleam/dict.{type Dict}
import gleam/dynamic.{type DecodeError, DecodeError}
import gleam/result

pub type Color {
  Fruit

  Pink
  Blue
  Orange
  Green
  Purple
}

pub fn color_to_string(color: Color) -> String {
  case color {
    Fruit -> "fruit"

    Pink -> "pink"
    Blue -> "blue"
    Orange -> "orange"
    Green -> "green"
    Purple -> "purple"
  }
}

pub fn string_to_color(color: String) -> Result(Color, List(DecodeError)) {
  case color {
    "fruit" -> Ok(Fruit)

    "pink" -> Ok(Pink)
    "blue" -> Ok(Blue)
    "orange" -> Ok(Orange)
    "green" -> Ok(Green)
    "purple" -> Ok(Purple)

    _ -> Error([DecodeError("valid color", color, path: [])])
  }
}

pub const field_size = #(50, 30)

pub type Field = Dict(Color, List(#(Int, Int)))

pub fn field_to_json(field: Field) -> String {
  field
  |> dict.to_list
  |> list.map(fn(color_into: #(Color, List(#(Int, Int)))) -> #(String, json.Json) {
    #(
      color_into.0 
        |> color_to_string, 
      json.array(
        color_into.1, 
        fn(coords: #(Int, Int)) {
          json.array([coords.0, coords.1], json.int)
        }
      )
    )
  })
  |> json.object
  |> json.to_string
}

pub fn json_to_field(json_string: String) -> Field {
  let field_decoder = dynamic.dict(
    fn(data: dynamic.Dynamic) -> Result(Color, List(DecodeError)) {
      data
      |> dynamic.string
      |> result.then(string_to_color)
    },
    dynamic.list(
      dynamic.tuple2(
        dynamic.int,
        dynamic.int,
      )
    )
  )

  json.decode(json_string, using: field_decoder)
  |> result.unwrap(dict.from_list([]))
}

pub type WsStateUpdate = Field

pub fn state_update_to_json(update: WsStateUpdate) -> String {
  field_to_json(update)
}

pub fn json_to_state_update(input: String) -> WsStateUpdate {
  json_to_field(input)
}

pub type WsPlayerAction {
  Up
  Left
  Down
  Right
  Nop
}

pub fn player_action_to_string(action: WsPlayerAction) -> String {
  case action {
    Up -> "up"
    Left -> "left"
    Down -> "down"
    Right -> "right"
    Nop -> ""
  }
}

pub fn string_to_player_action(input: String) -> Result(WsPlayerAction, List(DecodeError)) {
  case input {
    "up" -> Ok(Up)
    "left" -> Ok(Left)
    "down" -> Ok(Down)
    "right" -> Ok(Right)

    _ -> Error([DecodeError("up, left, down or right", input, path: [])])
  }
}

pub fn player_action_to_json(action: WsPlayerAction) -> String {
    json.object([
      #("direction", action |> player_action_to_string |> json.string),
    ])
    |> json.to_string
}

pub fn json_to_player_action(input: String) -> WsPlayerAction {
  let field_decoder = fn(data: dynamic.Dynamic) -> Result(WsPlayerAction, List(DecodeError)) {
    data
    |> dynamic.dict(dynamic.string, dynamic.string)
    |> result.then(fn(attributes: Dict(String, String)) -> Result(String, List(DecodeError)) {
      attributes
      |> dict.get("direction")
      |> result.map_error(fn(_: Nil) -> List(DecodeError) {[DecodeError("direction", "", [])]} )
    })
    |> result.then(string_to_player_action)
  }

  json.decode(input, using: field_decoder)
  |> result.unwrap(Nop)
}
