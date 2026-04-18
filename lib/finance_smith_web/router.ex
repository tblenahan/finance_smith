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
    post("/users/session", UserSessionController, :create)
    delete("/users/log_out", UserSessionController, :delete)
  end

  scope "/users/mfa", FinanceSmithWeb do
    pipe_through([:browser, FinanceSmithWeb.Plugs.RequireMfaPending])

    live_session :mfa_pending,
      on_mount: [{FinanceSmithWeb.Plugs.LiveAuth, :mfa_pending}] do
      live("/", MfaVerifyLive, :index)
    end
  end

  scope "/", FinanceSmithWeb do
    pipe_through([:browser, :require_authenticated, :require_mfa_verified])

    live_session :authenticated,
      on_mount: [{FinanceSmithWeb.Plugs.LiveAuth, :default}] do
      live("/dashboard", DashboardLive, :index)
      live("/connections/:plaid_item_id", ConnectionLive, :index)
      live("/accounts/:account_id", AccountLive, :index)
      live("/users/settings", UserSettingsLive, :index)
      live("/users/settings/mfa", MfaSetupLive, :index)
      live("/oauth/callback/plaid", OAuthCallbackLive, :index)
    end
  end
end
