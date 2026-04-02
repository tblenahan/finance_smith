defmodule FinanceSmith.Vault do
  use Cloak.Vault, otp_app: :finance_smith

  @impl GenServer
  def init(config) do
    config =
      case System.get_env("CLOAK_KEY") do
        nil ->
          # dev.exs / test.exs / runtime.exs supply ciphers; no env override needed
          config

        val ->
          Keyword.put(config, :ciphers,
            default: {
              Cloak.Ciphers.AES.GCM,
              tag: "AES.GCM.V1", key: Base.decode64!(val), iv_length: 12
            }
          )
      end

    {:ok, config}
  end
end
