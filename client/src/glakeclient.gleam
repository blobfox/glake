import gleam/dict.{type Dict, filter}
import gleam/iterator.{range, map, to_list, flat_map, append}
import gleam/pair.{first, second}
import gleam/result.{unwrap}
import gleam/list.{contains}
import gleam/option.{type Option, None, Some}


import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element
import lustre/event
import lustre/element/html

import lustre_websocket as ws

import gleam/json
import gleam/dynamic


const size = #(50, 30)

pub type Field = Dict(String, List(#(Int, Int)))

pub type Model {
  Model(
    field: Field,
    ws: Option(ws.WebSocket)
  )
}

pub type Msg {
  WsWrapper(ws.WebSocketEvent)
  Up 
  Left
  Down
  Right
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(Model(dict.from_list([]), None), ws.init("ws://localhost:8080/", WsWrapper))
}

pub fn parse_field(input: String) -> Field {
  let field_decoder = dynamic.dict(
    dynamic.string,
    dynamic.list(
      dynamic.tuple2(
        dynamic.int,
        dynamic.int,
      )
    )
  )

  json.decode(input, using: field_decoder)
  |> unwrap(dict.from_list([]))
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WsWrapper(ws.InvalidUrl) -> panic
    WsWrapper(ws.OnOpen(socket)) -> #(Model(..model, ws: Some(socket)), ws.send(socket, "client-init"))
    WsWrapper(ws.OnTextMessage(msg)) -> #(Model(..model, field: parse_field(msg)), effect.none())
    WsWrapper(ws.OnBinaryMessage(_msg)) -> todo as "either-or"
    WsWrapper(ws.OnClose(_reason)) -> #(Model(..model, ws: None), effect.none())
    
    Up -> todo
    Left -> todo
    Down -> todo
    Right -> todo
  }
}

pub fn get_color(model: Model, row: Int, column: Int) -> Result(String, Nil) {
  model.field
  |> filter(fn(_, value) {
    value |> contains(#(column, row))
  })
  |> dict.to_list
  |> list.map(fn(tuple) { first(tuple) })
  |> list.first
}

pub fn cell(model: Model, row: Int, column: Int) -> element.Element(Msg) {
  let base_class = "cell"
  let classes = 
    get_color(model, row, column)
    |> result.map(fn(color) { [color] })
    |> unwrap([])
    |> list.append([base_class])
    |> list.map(attribute.class)

  html.div(classes, [])
}

pub fn field(model: Model) -> element.Element(Msg) {
  html.div([attribute.id("field")], 
    range(from: 0, to: second(size) - 1)
    |> flat_map(fn(row) {
      range(from: 0, to: first(size) - 1)
      |> map(fn(column) {
        cell(model, row, column)
      })
      |> append(iterator.from_list([html.br([])]))
    })
    |> to_list()
  )
}

pub fn controls(model: Model) -> element.Element(Msg) {
  html.div([attribute.id("controls")], [
    html.button([attribute.class("up"), event.on_click(Up)], [element.text("⇧")]),
    html.button([attribute.class("left"), event.on_click(Left)], [element.text("⇦")]),
    html.button([attribute.class("down"), event.on_click(Down)], [element.text("⇩")]),
    html.button([attribute.class("right"), event.on_click(Right)], [element.text("⇨")]),
  ])
}

pub fn view(model: Model) -> element.Element(Msg) {
  html.div([attribute.id("app")],
    [
      html.h1([], [element.text("Hello World")]),
      field(model),
      controls(model)
    ]
  )
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}