import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
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
  let assert Ok(broadcaster) =
    actor.start(GameState(glakes: [], fruites: []), game_message_handler)

  let assert Ok(_) =
    mist_router(router, broadcaster, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start_http

  let t = ticker(broadcaster)
  process.start(t, True)
  process.sleep_forever()
}

// Router ------------------------------------------

fn mist_router(
  wisp_router: fn(Request(wisp.Connection)) -> wisp.Response,
  broadcaster: GameLoopSubject,
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
  broadcaster: GameLoopSubject,
) -> Response(ResponseData) {
  let on_init = on_init(_, broadcaster)
  let on_close = on_close(_, broadcaster)
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
  state: SocketState,
  connection: WebsocketConnection,
  message: WebsocketMessage(Message),
  game: GameLoopSubject,
) -> actor.Next(a, SocketState) {
  case message {
    mist.Text(text) -> {
      process.send(game, Broadcast(text))
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

type ClientSubject =
  Subject(Message)

type GameLoopSubject =
  Subject(GameMessage)

type GameMessage {
  Register(subject: ClientSubject)
  Unregister(subject: ClientSubject)
  Broadcast(text: String)
  Tick
}

type SocketState {
  SocketState(subject: ClientSubject)
}

type Message {
  Send(String)
}

type Glake {
  Glake(
    subject: ClientSubject,
    color: Color,
    direction: Direction,
    position: List(List(Int)),
  )
}

type GameState(a) {
  GameState(glakes: List(Glake), fruites: List(List(Int)))
}

fn game_message_handler(message: GameMessage, state: GameState(a)) {
  case message {
    // TODO: On Register the color should be dynamic added
    // TODO: If the game is full == every color is used, the WS Connection shoud be closed
    Register(subject) -> {
      // HACK: using list.append is ugly here
      list.append(state.glakes, [Glake(subject, Pink, Right, [[0, 0]])])
      |> GameState(state.fruites)
      |> actor.continue
    }
    Unregister(subject) -> {
      list.filter(state.glakes, fn(glake) { glake.subject != subject })
      |> GameState(state.fruites)
      |> actor.continue
    }
    Broadcast(_text) -> {
      state.glakes
      |> list.each(fn(glake) {
        process.send(glake.subject, Send(field_to_json(state.glakes)))
      })
      actor.continue(state)
    }
    Tick -> {
      actor.continue(state)
    }
  }
}

fn on_init(
  _connection: WebsocketConnection,
  broadcaster: GameLoopSubject,
) -> #(SocketState, Option(process.Selector(Message))) {
  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.selecting(subject, function.identity)

  process.send(broadcaster, Register(subject))
  #(SocketState(subject), option.Some(selector))
}

fn on_close(state: SocketState, broadcaster: GameLoopSubject) {
  process.send(broadcaster, Unregister(state.subject))
}

// Game -------------------------------------------------------

type Direction {
  Up
  Down
  Left
  Right
}

fn direction_to_string(direction: Direction) -> String {
  case direction {
    Up -> "up"
    Down -> "down"
    Left -> "left"
    Right -> "right"
  }
}

type Color {
  Pink
  White
  Blue
  Yellow
  Aubergine
  DarkBlue
  Charcoal
  Black
}

fn color_to_string(color: Color) -> String {
  case color {
    Pink -> "Pink"
    White -> "White"
    Blue -> "Blue"
    Yellow -> "Yellow"
    Aubergine -> "Aubergine"
    DarkBlue -> "DarkBlue"
    Charcoal -> "Charcoal"
    Black -> "Black"
  }
}

fn field_to_json(glakes: List(Glake)) -> String {
  list.map(glakes, fn(g) {
    #(
      color_to_string(g.color),
      json.array(g.position, of: json.array(_, of: json.int)),
    )
  })
  |> json.object()
  |> json.to_string
}

fn ticker(broadcaster: GameLoopSubject) {
  process.sleep(1000)
  process.send(broadcaster, Tick)
  // TODO: 
  process.send(broadcaster, Broadcast("right"))
  ticker(broadcaster)
}
