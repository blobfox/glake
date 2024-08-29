import common.{
  type Color, type Field, type WsPlayerAction as Direction, Down, Fruit, Left,
  Nop, Right, Up, field_size, field_to_json, json_to_player_action,
}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/iterator
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import mist.{type ResponseData, type WebsocketConnection, type WebsocketMessage}

pub fn websocket_view(
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

pub type ClientSubject =
  Subject(Message)

pub type GameLoopSubject =
  Subject(GameMessage)

pub type GameMessage {
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

pub type Message {
  Send(String)
  SetColor(Color)
}

pub type Glake {
  Glake(
    subject: ClientSubject,
    color: Color,
    direction: Direction,
    position: List(#(Int, Int)),
  )
}

pub type GameState {
  GameState(glakes: List(Glake), fruites: List(#(Int, Int)))
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

pub fn game_message_handler(message: GameMessage, state: GameState) {
  case message {
    // TODO: On Register the color should be dynamic added
    // TODO: If the game is full == every color is used, the WS Connection shoud be closed
    Register(subject) -> {
      let color = pick_free_color(state) |> list.first

      case color {
        Ok(color) -> {
          process.send(subject, SetColor(color))

          // HACK: using list.append is ugly here
          list.append(state.glakes, [spawn_glake(state, subject, color)])
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

const colors = [
  common.Pink, common.Blue, common.Orange, common.Green, common.Purple,
]

fn pick_free_color(state: GameState) -> List(Color) {
  // TODO: there is a list.contains function
  let used_colors =
    state.glakes |> list.map(fn(glake) { glake.color }) |> set.from_list

  colors |> set.from_list |> set.difference(used_colors) |> set.to_list
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

  let state_with_collisions =
    GameState(
      ..state_with_scores,
      glakes: state_with_scores.glakes
        |> list.map(calculate_collisions(_, state_with_scores)),
    )

  let state_with_new_fruits =
    GameState(
      ..state_with_collisions,
      fruites: state_with_collisions |> calculate_fruits,
    )

  state_with_new_fruits
}

const directions = [Up, Left, Down, Right]

fn spawn_glake(
  state: GameState,
  subject: Subject(Message),
  color: Color,
) -> Glake {
  let spawn_position = find_spawn_position(state)

  let direction =
    directions
    |> list.drop(int.random(4))
    |> list.first
    |> result.unwrap(Right)

  let spawn_offset = case direction {
    Up -> #(0, 1)
    Left -> #(1, 0)
    Down -> #(0, -1)
    Right -> #(-1, 0)
    Nop -> panic
  }

  Glake(subject: subject, color: color, direction: direction, position: [
    #(
      { spawn_position.0 + spawn_offset.0 + field_size.0 } % field_size.0,
      { spawn_position.1 + spawn_offset.1 + field_size.1 } % field_size.1,
    ),
    spawn_position,
  ])
}

fn get_head(glake: Glake) -> #(Int, Int) {
  glake.position
  |> list.last
  |> result.unwrap(#(0, 0))
  // this will never happen but we need a default
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

fn find_spawn_position(state: GameState) -> #(Int, Int) {
  iterator.from_list([Nil])
  |> iterator.cycle
  |> iterator.map(fn(_) -> #(Int, Int) {
    #(int.random(field_size.0), int.random(field_size.1))
  })
  |> iterator.drop_while(fn(position: #(Int, Int)) {
    let position_that_need_to_be_free = [
      #(
        { position.0 - 2 + field_size.0 } % field_size.0,
        { position.1 - 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 1 + field_size.0 } % field_size.0,
        { position.1 - 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 0 + field_size.0 } % field_size.0,
        { position.1 - 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 1 + field_size.0 } % field_size.0,
        { position.1 - 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 2 + field_size.0 } % field_size.0,
        { position.1 - 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 2 + field_size.0 } % field_size.0,
        { position.1 - 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 1 + field_size.0 } % field_size.0,
        { position.1 - 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 0 + field_size.0 } % field_size.0,
        { position.1 - 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 1 + field_size.0 } % field_size.0,
        { position.1 - 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 2 + field_size.0 } % field_size.0,
        { position.1 - 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 2 + field_size.0 } % field_size.0,
        { position.1 + 0 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 1 + field_size.0 } % field_size.0,
        { position.1 + 0 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 0 + field_size.0 } % field_size.0,
        { position.1 + 0 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 1 + field_size.0 } % field_size.0,
        { position.1 + 0 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 2 + field_size.0 } % field_size.0,
        { position.1 + 0 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 2 + field_size.0 } % field_size.0,
        { position.1 + 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 1 + field_size.0 } % field_size.0,
        { position.1 + 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 0 + field_size.0 } % field_size.0,
        { position.1 + 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 1 + field_size.0 } % field_size.0,
        { position.1 + 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 2 + field_size.0 } % field_size.0,
        { position.1 + 1 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 2 + field_size.0 } % field_size.0,
        { position.1 + 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 - 1 + field_size.0 } % field_size.0,
        { position.1 + 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 0 + field_size.0 } % field_size.0,
        { position.1 + 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 1 + field_size.0 } % field_size.0,
        { position.1 + 2 + field_size.1 } % field_size.1,
      ),
      #(
        { position.0 + 2 + field_size.0 } % field_size.0,
        { position.1 + 2 + field_size.1 } % field_size.1,
      ),
    ]

    position_that_need_to_be_free
    |> list.any(fn(position_to_check: #(Int, Int)) {
      {
        state.glakes
        |> list.any(fn(glake: Glake) {
          glake.position
          |> list.contains(position_to_check)
        })
      }
      || {
        state.fruites
        |> list.contains(position_to_check)
      }
    })
  })
  |> iterator.first
  |> result.unwrap(#(0, 0))
  // shouldn't happen
}

fn calculate_glake_length(glake: Glake, state: GameState) -> Glake {
  case state.fruites |> list.contains(glake |> get_head) {
    True -> glake
    _ -> Glake(..glake, position: glake.position |> list.drop(1))
  }
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

fn calculate_collisions(glake: Glake, state: GameState) -> Glake {
  // todo
  let head = glake |> get_head
  let has_collision_with_other_glake =
    state.glakes
    |> list.filter(fn(other_glake: Glake) { glake.color != other_glake.color })
    |> list.any(fn(other_glake: Glake) {
      other_glake.position
      |> list.contains(head)
    })
  let has_collusion_with_self =
    glake.position
    |> list.reverse
    |> list.drop(1)
    |> list.contains(head)

  case has_collision_with_other_glake || has_collusion_with_self {
    True -> spawn_glake(state, glake.subject, glake.color)
    _ -> glake
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

pub fn ticker(broadcaster: GameLoopSubject) {
  process.sleep(300)
  process.send(broadcaster, Tick)
  ticker(broadcaster)
}
