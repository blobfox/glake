import gleam/option.{type Option}

import lustre_websocket as ws

import common.{type Field}

pub type Model {
  Model(field: Field, ws: Option(ws.WebSocket))
}
