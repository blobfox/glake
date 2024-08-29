import wisp.{type Request, type Response}
import gleam/http.{Get}
import lustre/element/html.{html}
import lustre/attribute
import lustre/element

pub fn home_view(request: Request) -> Response {
  case request.method {
    Get -> home_controller(request)
    _ -> wisp.method_not_allowed([http.Get])
  }
}

fn home_controller(_request: wisp.Request) -> wisp.Response {
  html([], [
    html.head([], [
      html.link([
        attribute.rel("stylesheet"),
        attribute.href("/static/styles.css"),
      ]),
      html.script(
        [attribute.type_("module"), attribute.src("/static/client.mjs")],
        "",
      ),
    ]),
    html.body([], [html.div([attribute.id("app")], [])]),
  ])
  |> element.to_document_string_builder
  |> wisp.html_response(200)
}


