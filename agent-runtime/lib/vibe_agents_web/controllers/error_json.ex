defmodule VibeAgentsWeb.ErrorJSON do
  @moduledoc "Renders `%{errors: %{detail: ...}}` for any status Phoenix falls back to."

  def render("413.json", %{reason: %Plug.Parsers.RequestTooLargeError{}}) do
    %{errors: %{detail: "Request entity too large", code: 413}}
  end

  def render(template, _assigns) when is_binary(template) do
    detail =
      case String.split(template, ".", parts: 2) do
        [code, "json"] ->
          case Integer.parse(code) do
            {status_code, _} -> Plug.Conn.Status.reason_phrase(status_code) || "Error"
            _ -> "Error"
          end

        _ ->
          "Error"
      end

    %{errors: %{detail: detail}}
  end
end
