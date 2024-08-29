import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type ResponseData}
import mist/internal/http
import web/websocket.{type GameLoopSubject}
import wisp
import wisp/wisp_mist
import web/home 

pub fn mist_router(
  wisp_router: fn(Request(wisp.Connection)) -> wisp.Response,
  broadcaster: GameLoopSubject,
  secret_key: String,
) -> fn(Request(http.Connection)) -> Response(ResponseData) {
  fn(request: Request(mist.Connection)) -> Response(ResponseData) {
    case request.path_segments(request) {
      ["ws"] -> websocket.websocket_view(request, broadcaster)
      _ -> wisp_mist.handler(wisp_router, secret_key)(request)
    }
  }
}

pub fn router(request: wisp.Request) -> wisp.Response {
  use req <- middleware(request)

  case wisp.path_segments(req) {
    [] -> home.home_view(request)
    _ -> wisp.not_found()
  }
}

pub fn static_directory() -> String {
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  priv_directory <> "/static"
}

fn middleware(
  request: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let request = wisp.method_override(request)
  use <- wisp.log_request(request)
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use <- wisp.serve_static(request, under: "/static", from: static_directory())

  handle_request(request)
}
