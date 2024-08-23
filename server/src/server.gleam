import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/string_builder
import mist
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    wisp_mist.handler(router, secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start_http

  process.sleep_forever()
}

fn start_webserver(
  port: Int,
) -> fn(response.Response(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  wisp.configure_logger()

  let secret_key_base = wisp.random_string(64)
  let wisp_side = wisp_mist.handler(router(_), secret_key_base)
  fn(req) {
    case request.path_segments(req) {
      ["ws"] -> websocket_view(req)
      _ -> wisp_side(req)
    }
  }
}

// Router ------------------------------------------

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

fn websocket_view(request: wisp.Request) -> response.Response(mist.ResponseData) {
  mist.websocket()
}

// Controller ----------------------------------------

fn home_controller(_request: wisp.Request) -> wisp.Response {
  "<h1>Hello o/</h1>"
  |> string_builder.from_string
  |> wisp.html_response(200)
}
