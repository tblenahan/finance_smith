defmodule FinanceSmith.Vault do
  @moduledoc """
  Cloak vault for encrypting sensitive attributes (mfa_secret, recovery_codes).

  Cipher configuration is supplied per environment:
    - dev/test: project `.env` is merged into env in `config/config.exs`, then
      `CLOAK_KEY` / `CLOAK_KEY_TEST` are read in `config/dev.exs` and `config/test.exs`
    - prod: `config/runtime.exs` (`CLOAK_KEY` required)
  """
  use Cloak.Vault, otp_app: :finance_smith
end
