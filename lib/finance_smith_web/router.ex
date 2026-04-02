defmodule FinanceSmithWeb.Router do
  use FinanceSmithWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FinanceSmithWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(FinanceSmithWeb.UserAuth)
  end

  pipeline :require_authenticated do
    plug(FinanceSmithWeb.Plugs.RequireAuthenticated)
  end

  pipeline :require_mfa_verified do
    plug(FinanceSmithWeb.Plugs.RequireMfaVerified)
  end

  scope "/", FinanceSmithWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
    live("/users/log_in", UserLoginLive, :new)
    live("/users/register", UserRegistrationLive, :new)
    get("/users/session", UserSessionController, :create)
    delete("/users/log_out", UserAuth, :delete)
  end

  scope "/users/mfa", FinanceSmithWeb do
    pipe_through([:browser, FinanceSmithWeb.Plugs.RequireMfaPending])
    live("/", MfaVerifyLive, :index)
  end

  scope "/", FinanceSmithWeb do
    pipe_through([:browser, :require_authenticated, :require_mfa_verified])

    live("/dashboard", DashboardLive, :index)
    live("/users/settings", UserSettingsLive, :index)
    live("/users/settings/mfa", MfaSetupLive, :index)
  end
end
