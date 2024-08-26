import common.{
  type Color, type Field, type WsPlayerAction as Direction, Down, Fruit, Left,
  Nop, Right, Up, field_size, field_to_json, json_to_player_action,
}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
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
  _game: GameLoopSubject,
) -> actor.Next(Message, SocketState) {
  case message {
    mist.Text(text) -> {
      case state.color {
        Some(color) ->
          text
          |> json_to_player_action
          |> PlayerAction(color, _)
          |> process.send(state.broadcaster, _)
        None -> Nil
      }

      actor.continue(state)
    }
    mist.Text(_) | mist.Binary(_) -> {
      actor.continue(state)
    }
    mist.Custom(Send(text)) -> {
      let assert Ok(_) = mist.send_text_frame(connection, text)
      actor.continue(state)
    }
    mist.Custom(SetColor(color)) -> {
      actor.continue(SocketState(..state, color: Some(color)))
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
  PlayerAction(color: Color, direction: Direction)
  Tick
}

type SocketState {
  SocketState(
    color: Option(Color),
    broadcaster: GameLoopSubject,
    subject: ClientSubject,
  )
}

type Message {
  Send(String)
  SetColor(Color)
}

type Glake {
  Glake(
    subject: ClientSubject,
    color: Color,
    direction: Direction,
    position: List(#(Int, Int)),
  )
}

type GameState {
  GameState(glakes: List(Glake), fruites: List(#(Int, Int)))
}

const colors = [
  common.Pink, common.Blue, common.Orange, common.Green, common.Purple,
]

fn pick_free_color(state: GameState) -> List(Color) {
  // TODO: there is a list.contains function
  let used_colors =
    state.glakes |> list.map(fn(glake) { glake.color }) |> set.from_list

  colors |> set.from_list |> set.difference(used_colors) |> set.to_list
}

fn game_message_handler(message: GameMessage, state: GameState) {
  case message {
    // TODO: On Register the color should be dynamic added
    // TODO: If the game is full == every color is used, the WS Connection shoud be closed
    Register(subject) -> {
      let color = pick_free_color(state) |> list.first

      case color {
        Ok(color) -> {
          process.send(subject, SetColor(color))

          // HACK: using list.append is ugly here
          list.append(state.glakes, [
            Glake(subject, color, common.Right, [#(0, 0)]),
          ])
          |> GameState(state.fruites)
          |> actor.continue
        }
        // TODO: Handle this Error
        Error(_) -> todo
      }
    }
    Unregister(subject) -> {
      list.filter(state.glakes, fn(glake) { glake.subject != subject })
      |> GameState(state.fruites)
      |> actor.continue
    }
    PlayerAction(color, direction) -> {
      state.glakes
      |> list.map(fn(glake: Glake) -> Glake {
        case glake.color == color && direction != Nop {
          True -> Glake(..glake, direction: direction)
          _ -> glake
        }
      })
      |> GameState(state.fruites)
      |> actor.continue
    }
    Tick -> {
      let next_state = state |> calculate_board
      next_state.glakes
      |> list.each(fn(glake) {
        next_state
        |> make_field
        |> field_to_json
        |> Send
        |> process.send(glake.subject, _)
      })
      next_state |> actor.continue
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
  #(SocketState(None, broadcaster, subject), option.Some(selector))
}

fn on_close(state: SocketState, broadcaster: GameLoopSubject) {
  process.send(broadcaster, Unregister(state.subject))
}

fn make_field(state: GameState) -> Field {
  state.glakes
  |> list.map(fn(glake: Glake) -> #(Color, List(#(Int, Int))) {
    #(glake.color, glake.position)
  })
  |> dict.from_list
  |> dict.insert(Fruit, state.fruites)
}

fn calculate_board(state: GameState) -> GameState {
  let state_with_moves =
    GameState(
      ..state,
      glakes: state.glakes |> list.map(caluclate_glake_movement),
    )

  let state_with_scores =
    GameState(
      glakes: state_with_moves.glakes
        |> list.map(calculate_glake_length(_, state_with_moves)),
      fruites: calculate_eaten_fruites(state_with_moves),
    )

  let state_with_new_fruits =
    GameState(
      ..state_with_scores,
      fruites: state_with_scores |> calculate_fruits,
    )

  state_with_new_fruits
}

fn get_head(glake: Glake) -> #(Int, Int) {
  glake.position
  |> list.last
  |> result.unwrap(#(0, 0))
  // this will never happen but we need a default
}

fn calculate_eaten_fruites(state: GameState) -> List(#(Int, Int)) {
  state.fruites
  |> list.filter(fn(fruit: #(Int, Int)) {
    !{
      state.glakes
      |> list.map(get_head)
      |> list.contains(fruit)
    }
  })
}

fn calculate_glake_length(glake: Glake, state: GameState) -> Glake {
  case state.fruites |> list.contains(glake |> get_head) {
    True -> glake
    _ -> Glake(..glake, position: glake.position |> list.drop(1))
  }
}

const target_fruits = 5

fn calculate_fruits(state: GameState) -> List(#(Int, Int)) {
  let missing_fruits = target_fruits - { state.fruites |> list.length }
  list.range(0, int.max(0, missing_fruits))
  |> list.drop(1)
  // ugly, but otherwise range(0, 0) will return an empty list
  |> list.map(fn(_) -> #(Int, Int) {
    #(int.random(field_size.0), int.random(field_size.1))
  })
  |> list.append(state.fruites)
  |> list.unique
  |> list.filter(fn(position: #(Int, Int)) {
    state.glakes
    |> list.all(fn(glake: Glake) {
      !{ glake.position |> list.contains(position) }
    })
  })
}

fn caluclate_glake_movement(glake: Glake) -> Glake {
  let old_head = glake |> get_head
  let new_head = case glake.direction {
    Up -> #(old_head.0, { old_head.1 - 1 + field_size.1 } % field_size.1)
    Left -> #({ old_head.0 - 1 + field_size.0 } % field_size.0, old_head.1)
    Down -> #(old_head.0, { old_head.1 + 1 } % field_size.1)
    Right -> #({ old_head.0 + 1 } % field_size.0, old_head.1)
    Nop -> panic
  }

  Glake(..glake, position: glake.position |> list.append([new_head]))
}

fn ticker(broadcaster: GameLoopSubject) {
  process.sleep(300)
  process.send(broadcaster, Tick)
  ticker(broadcaster)
}
