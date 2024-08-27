import gleam/option.{None, Some}

import lustre/effect.{type Effect}

import lustre_websocket as ws

import plinth/browser/document
import plinth/browser/event as dom_event

import common.{type WsPlayerAction, json_to_field, player_action_to_json}

import model.{type Model, Model}

pub type Msg {
  WsWrapper(ws.WebSocketEvent)
  Up
  Left
  Down
  Right
  Nop
}

fn key_to_msg(key: String) -> Msg {
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

pub fn global_events(dispatch: fn(Msg) -> Nil) -> Nil {
  document.add_event_listener("keydown", fn(event: dom_event.Event) -> Nil {
    event
    |> dom_event.key
    |> key_to_msg
    |> dispatch
  })
}

fn send_update(model: Model, msg: Msg) -> Effect(Msg) {
  model.ws
  |> option.map(fn(socket: ws.WebSocket) -> Effect(Msg) {
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
    WsWrapper(ws.OnOpen(socket)) -> #(
      Model(..model, ws: Some(socket)),
      ws.send(socket, "client-init"),
    )
    WsWrapper(ws.OnTextMessage(msg)) -> #(
      Model(..model, field: json_to_field(msg)),
      effect.none(),
    )
    WsWrapper(ws.OnBinaryMessage(_msg)) -> panic
    WsWrapper(ws.OnClose(_reason)) -> #(Model(..model, ws: None), effect.none())

    Up | Left | Down | Right -> #(model, send_update(model, msg))
    Nop -> #(model, effect.none())
  }
}
