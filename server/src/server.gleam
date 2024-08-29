import gleam/erlang/process
import gleam/otp/actor
import mist
import web/router.{mist_router, router}
import web/websocket.{game_message_handler, ticker}
import wisp

pub fn main() {
  start_webserver(webserver_port: 8000)
}

fn start_webserver(webserver_port port: Int) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)
  let assert Ok(broadcaster) =
    actor.start(
      websocket.GameState(glakes: [], fruites: []),
      game_message_handler,
    )

  let assert Ok(_) =
    mist_router(router, broadcaster, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start_http

  let t = ticker(broadcaster)
  process.start(t, True)
  process.sleep_forever()
}
