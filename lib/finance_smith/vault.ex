defmodule FinanceSmith.Vault do
  @moduledoc """
  Cloak vault for encrypting sensitive attributes (mfa_secret, recovery_codes).

  Cipher configuration is supplied per environment:
    - dev/test/prod: project `.env` is merged into env in `config/config.exs` when the file exists
      (prod: prefer platform-injected env in real deployments)
    - dev/test: `CLOAK_KEY` / `CLOAK_KEY_TEST` in `config/dev.exs` and `config/test.exs`
    - prod: `CLOAK_KEY` in `config/runtime.exs`
  """
  use Cloak.Vault, otp_app: :finance_smith
end
