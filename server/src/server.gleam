import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/option
import gleam/otp/actor
import gleam/string_builder
import mist.{
  type Connection, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}
import mist/internal/http as mist_http
import wisp
import wisp/wisp_mist

pub fn main() {
  start_webserver(webserver_port: 8000)
}

fn start_webserver(webserver_port port: Int) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    mist_router(router, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start_http

  process.sleep_forever()
}

// Router ------------------------------------------

fn mist_router(
  wisp_router: fn(Request(wisp.Connection)) -> wisp.Response,
  secret_key: String,
) -> fn(Request(mist_http.Connection)) -> Response(ResponseData) {
  fn(request: Request(Connection)) -> Response(ResponseData) {
    case request.path_segments(request) {
      ["ws"] -> websocket_view(request)
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

fn websocket_view(request: Request(mist.Connection)) -> Response(ResponseData) {
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
  message: WebsocketMessage(message),
) {
  case message {
    mist.Text(text) -> {
      let assert Ok(_) = mist.send_text_frame(connection, text)
      actor.continue(state)
    }
    mist.Text(_) | mist.Binary(_) -> {
      actor.continue(state)
    }
    mist.Custom(_) -> {
      let assert Ok(_) = mist.send_text_frame(connection, "Hi")
      actor.continue(state)
    }
    mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
  }
}

// Websocket utils ------------------------------------

fn on_init(
  _connection: WebsocketConnection,
) -> #(Nil, option.Option(process.Selector(message))) {
  let selector = process.new_selector()
  let state = Nil

  #(state, option.Some(selector))
}

fn on_close(_state) {
  io.print("connection closed")
}
