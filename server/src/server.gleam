import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string_builder
import mist.{type ResponseData, type WebsocketConnection, type WebsocketMessage}
import mist/internal/http as mist_http
import wisp
import wisp/wisp_mist

pub fn main() {
  start_webserver(webserver_port: 8000)
}

fn start_webserver(webserver_port port: Int) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)
  let assert Ok(broadcaster) = actor.start([], broadcast_handle_message)

  let assert Ok(_) =
    mist_router(router, broadcaster, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start_http

  process.sleep_forever()
}

// Router ------------------------------------------

fn mist_router(
  wisp_router: fn(Request(wisp.Connection)) -> wisp.Response,
  broadcaster: Subject(BroadcastMessage(Message)),
  secret_key: String,
) -> fn(Request(mist_http.Connection)) -> Response(ResponseData) {
  fn(request: Request(mist.Connection)) -> Response(ResponseData) {
    case request.path_segments(request) {
      ["ws"] -> websocket_view(request, broadcaster)
      _ -> wisp_mist.handler(wisp_router, secret_key)(request)
    }
  }
}

fn router(request: wisp.Request) -> wisp.Response {
  use req <- middleware(request)

  case wisp.path_segments(req) {
    [] -> home_view(request)
    _ -> wisp.not_found()
  }
}

fn middleware(
  request: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let request = wisp.method_override(request)
  use <- wisp.log_request(request)
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  handle_request(request)
}

// View ----------------------------------------------

fn home_view(request: wisp.Request) -> wisp.Response {
  case request.method {
    http.Get -> home_controller(request)
    _ -> wisp.method_not_allowed([http.Get])
  }
}

fn websocket_view(
  request: Request(mist.Connection),
  broadcaster: Subject(BroadcastMessage(Message)),
) -> Response(ResponseData) {
  let on_init = on_init(_, broadcaster)
  let websocket_controller = fn(state, connection, message) {
    websocket_controller(state, connection, message, broadcaster)
  }

  mist.websocket(
    request: request,
    on_init: on_init,
    on_close: on_close,
    handler: websocket_controller,
  )
}

// Controller ----------------------------------------

fn home_controller(_request: wisp.Request) -> wisp.Response {
  "<h1>Hello o/</h1>"
  |> string_builder.from_string
  |> wisp.html_response(200)
}

fn websocket_controller(
  state,
  connection: WebsocketConnection,
  message: WebsocketMessage(Message),
  broadcaster: Subject(BroadcastMessage(Message)),
) {
  case message {
    mist.Text(text) -> {
      process.send(broadcaster, Broadcast(Send(text)))
      actor.continue(state)
    }
    mist.Text(_) | mist.Binary(_) -> {
      actor.continue(state)
    }
    mist.Custom(Send(text)) -> {
      let assert Ok(_) = mist.send_text_frame(connection, text)
      actor.continue(state)
    }
    mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
  }
}

// Websocket utils ------------------------------------

type BroadcastMessage(a) {
  Register(subject: Subject(a))
  Unregister(subject: Subject(a))
  Broadcast(msg: a)
}

type SocketState {
  SocketState(subject: Subject(Message))
}

type Message {
  Send(String)
}

fn broadcast_handle_message(
  message: BroadcastMessage(a),
  destionations: List(process.Subject(a)),
) {
  case message {
    Register(subject) -> actor.continue([subject, ..destionations])
    Unregister(subject) ->
      actor.continue(
        destionations |> list.filter(fn(destination) { destination != subject }),
      )
    Broadcast(inner) -> {
      destionations
      |> list.each(fn(dest) { process.send(dest, inner) })
      actor.continue(destionations)
    }
  }
}

fn on_init(
  connection: WebsocketConnection,
  broadcaster: Subject(BroadcastMessage(Message)),
) -> #(SocketState, Option(process.Selector(Message))) {
  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.selecting(subject, function.identity)

  process.send(broadcaster, Register(subject))
  io.debug(connection)
  #(SocketState(subject), option.Some(selector))
}

fn on_close(_state) {
  io.print("connection closed")
}

// Game -------------------------------------------------------

fn game_loop(broadcaster: Subject(BroadcastMessage(Message))) {
  process.send(broadcaster, Broadcast(Send("Test")))
  game_loop(broadcaster)
}
