import gleam/dict.{filter}
import gleam/iterator.{range, map, to_list, flat_map, append}
import gleam/result
import gleam/list.{contains}
import gleam/option.{type Option, None, Some}


import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element
import lustre/event
import lustre/element/html

import plinth/browser/document
import plinth/browser/event as dom_event

import lustre_websocket as ws

import common.{type WsPlayerAction, player_action_to_json, type Field, json_to_field, field_size, type Color, color_to_string}


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
  Nop
}

pub fn key_to_msg(key: String) -> Msg {
  case key {
    "ArrowUp" -> Up
    "ArrowLeft" -> Left
    "ArrowDown" -> Down
    "ArrowRight" -> Right
    _ -> Nop
  }
}

fn msg_to_player_action(msg: Msg) -> WsPlayerAction {
  case msg {
    Up -> common.Up
    Left -> common.Left
    Down -> common.Down
    Right -> common.Right
    _ -> common.Nop
  }
}

fn global_events(dispatch: fn(Msg) -> Nil) -> Nil {
  document.add_event_listener("keydown", fn(event: dom_event.Event) -> Nil {
    event |> dom_event.key |> key_to_msg |> dispatch
  })
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(dict.from_list([]), None), 
    effect.batch([
      ws.init("ws://localhost:8080/", WsWrapper),
      effect.from(global_events),
    ])
  )
}

pub fn send_update(model: Model, msg: Msg) -> Effect(Msg) {
  model.ws
  |> option.map(fn (socket: ws.WebSocket) -> Effect(Msg) {
    msg
    |> msg_to_player_action
    |> player_action_to_json
    |> ws.send(socket, _)
  })
  |> option.unwrap(effect.none())
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WsWrapper(ws.InvalidUrl) -> panic
    WsWrapper(ws.OnOpen(socket)) -> #(Model(..model, ws: Some(socket)), ws.send(socket, "client-init"))
    WsWrapper(ws.OnTextMessage(msg)) -> #(Model(..model, field: json_to_field(msg)), effect.none())
    WsWrapper(ws.OnBinaryMessage(_msg)) -> todo as "either-or"
    WsWrapper(ws.OnClose(_reason)) -> #(Model(..model, ws: None), effect.none())
    
    Up | Left | Down | Right -> #(model, send_update(model, msg))
    Nop -> #(model, effect.none())
  }
}

pub fn get_color(model: Model, row: Int, column: Int) -> Result(Color, Nil) {
  model.field
  |> filter(fn(_, value) {
    value |> contains(#(column, row))
  })
  |> dict.to_list
  |> list.map(fn(tuple) { tuple.0 })
  |> list.first
}

pub fn cell(model: Model, row: Int, column: Int) -> element.Element(Msg) {
  let base_class = "cell"
  let classes = 
    get_color(model, row, column)
    |> result.map(color_to_string)
    |> result.map(fn(color) { [color] })
    |> result.unwrap([])
    |> list.append([base_class])
    |> list.map(attribute.class)

  html.div(classes, [])
}

pub fn field(model: Model) -> element.Element(Msg) {
  html.div([attribute.id("field")], 
    range(from: 0, to: field_size.1 - 1)
    |> flat_map(fn(row) {
      range(from: 0, to: field_size.0 - 1)
      |> map(fn(column) {
        cell(model, row, column)
      })
      |> append(iterator.from_list([html.br([])]))
    })
    |> to_list()
  )
}

pub fn controls() -> element.Element(Msg) {
  html.div([attribute.id("controls")], [
    html.button([attribute.class("up"), event.on_click(Up)], [element.text("⇧")]),
    html.button([attribute.class("left"), event.on_click(Left)], [element.text("⇦")]),
    html.button([attribute.class("down"), event.on_click(Down)], [element.text("⇩")]),
    html.button([attribute.class("right"), event.on_click(Right)], [element.text("⇨")]),
  ])
}

pub fn view(model: Model) -> element.Element(Msg) {
  html.div([
      attribute.id("app"),
    ],
    [
      html.h1([], [element.text("Hello World")]),
      field(model),
      controls()
    ]
  )
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}