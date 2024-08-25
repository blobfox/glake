import gleam/result
import gleam/list
import gleam/dict
import gleam/iterator

import lustre/attribute
import lustre/element
import lustre/event
import lustre/element/html

import common.{type Color, color_to_string, field_size}

import model.{type Model}
import messages.{type Msg, Up, Left, Down, Right}

fn get_color(model: Model, row: Int, column: Int) -> Result(Color, Nil) {
  model.field
  |> dict.filter(fn(_, value) {
    value |> list.contains(#(column, row))
  })
  |> dict.to_list
  |> list.map(fn(tuple) { tuple.0 })
  |> list.first
}

fn cell(model: Model, row: Int, column: Int) -> element.Element(Msg) {
  let base_class = "cell"
  let classes = 
    get_color(model, row, column)
    |> result.map(color_to_string)
    |> result.map(fn(color) { [color] })
    |> result.unwrap([])
    |> list.append([base_class])
    |> list.map(attribute.class)

  html.div(classes, [])
}

fn field(model: Model) -> element.Element(Msg) {
  html.div([attribute.id("field")], 
    iterator.range(from: 0, to: field_size.1 - 1)
    |> iterator.flat_map(fn(row) {
      iterator.range(from: 0, to: field_size.0 - 1)
      |> iterator.map(fn(column) {
        cell(model, row, column)
      })
      |> iterator.append(iterator.from_list([html.br([])]))
    })
    |> iterator.to_list()
  )
}

fn controls() -> element.Element(Msg) {
  html.div([attribute.id("controls")], [
    html.button([attribute.class("up"), event.on_click(Up)], [element.text("⇧")]),
    html.button([attribute.class("left"), event.on_click(Left)], [element.text("⇦")]),
    html.button([attribute.class("down"), event.on_click(Down)], [element.text("⇩")]),
    html.button([attribute.class("right"), event.on_click(Right)], [element.text("⇨")]),
  ])
}

pub fn view(model: Model) -> element.Element(Msg) {
  html.div([
      attribute.id("app"),
    ],
    [
      html.h1([], [element.text("Hello World")]),
      field(model),
      controls()
    ]
  )
}