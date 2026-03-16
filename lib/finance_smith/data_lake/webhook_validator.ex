defmodule FinanceSmith.DataLake.WebhookValidator do
  @moduledoc """
  Validates HMAC-SHA256 signatures on Backblaze B2 event notification webhooks.

  B2 signs each webhook request body using the HMAC-SHA256 signing secret
  configured on the Event Notification Rule. The signature is delivered in the
  `X-Bz-Event-Notification-Signature` header with the format `v1=<hex_digest>`.

  The comparison uses the output of HMAC applied to both values, which prevents
  timing side-channels — the comparison time is independent of where the byte
  sequences first differ.

  ## NFR-1.3 compliance

  Before downloading the B2 file, the Elixir worker MUST call `valid?/2` and
  discard the message immediately if it returns `false`.
  """

  @signature_version "v1"

  @doc """
  Returns `true` if the `signature_header` value is a valid HMAC-SHA256
  signature of `message_body` using the configured B2 webhook signing secret.

  `signature_header` must be in the form `v1=<hex_digest>`.
  """
  @spec valid?(binary(), String.t() | nil) :: boolean()
  def valid?(_message_body, nil), do: false
  def valid?(_message_body, ""), do: false

  def valid?(message_body, signature_header) do
    case parse_signature(signature_header) do
      {:ok, received_hex} ->
        secret = signing_secret()
        expected_hex = compute_hmac(secret, message_body)
        secure_equal?(expected_hex, received_hex)

      :error ->
        false
    end
  end

  # --- Private helpers ------------------------------------------------------

  defp parse_signature(header) do
    case String.split(header, "=", parts: 2) do
      [@signature_version, hex] when hex != "" -> {:ok, String.downcase(hex)}
      _ -> :error
    end
  end

  defp compute_hmac(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  # Compares two values in constant time by comparing their HMACs under a
  # random ephemeral key. This avoids timing leakage regardless of OTP version.
  defp secure_equal?(a, b) do
    key = :crypto.strong_rand_bytes(32)
    :crypto.mac(:hmac, :sha256, key, a) == :crypto.mac(:hmac, :sha256, key, b)
  end

  defp signing_secret do
    Application.fetch_env!(:finance_smith, :b2)
    |> Keyword.fetch!(:webhook_signing_secret)
  end
end
