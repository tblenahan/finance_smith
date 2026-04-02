defmodule FinanceSmithWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :finance_smith

  @session_options [
    store: :cookie,
    key: "_finance_smith_key",
    signing_salt: "finance_smith_session"
  ]

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Static,
    at: "/",
    from: :finance_smith,
    gzip: false,
    only: FinanceSmithWeb.static_paths(),
    cache_control_for_etags:
      Application.compile_env(:finance_smith, __MODULE__)[:static_cache_control]
  )

  plug(:favicon_fallback)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(FinanceSmithWeb.Router)

  defp favicon_fallback(conn, _opts) do
    if conn.method == "GET" and conn.path_info == ["favicon.ico"] do
      conn
      |> Plug.Conn.send_resp(204, "")
      |> Plug.Conn.halt()
    else
      conn
    end
  end
end
