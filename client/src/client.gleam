import gleam/dict
import gleam/option.{None}

import lustre
import lustre/effect.{type Effect}

import lustre_websocket as ws

import messages.{type Msg, WsWrapper, global_events, update}
import model.{type Model, Model}
import view.{view}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(dict.from_list([]), None), 
    effect.batch([
      ws.init("ws://localhost:8000/ws", WsWrapper),
      effect.from(global_events),
    ])
  )
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}