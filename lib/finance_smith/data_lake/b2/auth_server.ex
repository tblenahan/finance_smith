defmodule FinanceSmith.DataLake.B2.AuthServer do
  @moduledoc """
  GenServer that manages B2 authorization credentials in memory.

  On startup, calls `b2_authorize_account` with the configured key ID and
  application key via `handle_continue`, so a credential failure does not crash
  the supervision tree. If the application key is bucket-scoped (per NFR-1.4),
  the bucket ID is extracted directly from the authorization response. Otherwise,
  a `b2_list_buckets` call resolves the configured bucket name to its ID.

  The authorization token is valid for 24 hours and held exclusively in BEAM
  process memory — never written to disk, cleared on process restart.

  Callers receive `{:error, :not_authenticated}` when credentials are missing or
  authorization has not yet completed. A `refresh/0` call re-runs authorization
  immediately.
  """

  use GenServer

  require Logger

  @authorize_url "https://api.backblazeb2.com/b2api/v3/b2_authorize_account"

  defstruct [
    :authorization_token,
    :api_url,
    :download_url,
    :bucket_id,
    :bucket_name,
    :account_id
  ]

  # --- Public API -----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current cached auth state."
  @spec get_auth() :: {:ok, %__MODULE__{}} | {:error, :not_authenticated | term()}
  def get_auth do
    GenServer.call(__MODULE__, :get_auth)
  end

  @doc "Forces re-authorization with B2, replacing the cached token."
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, nil, {:continue, :authorize}}
  end

  @impl true
  def handle_continue(:authorize, _state) do
    case authorize() do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error(
          "[B2.AuthServer] Initial authorization failed: #{inspect(reason)}. B2 uploads and downloads will be unavailable until refresh/0 is called."
        )

        {:noreply, nil}
    end
  end

  @impl true
  def handle_call(:get_auth, _from, nil) do
    {:reply, {:error, :not_authenticated}, nil}
  end

  def handle_call(:get_auth, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:refresh, _from, _state) do
    case authorize() do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("[B2.AuthServer] Refresh failed: #{inspect(reason)}")
        {:reply, {:error, reason}, nil}
    end
  end

  # --- Private helpers ------------------------------------------------------

  defp authorize do
    config = Application.fetch_env!(:finance_smith, :b2)
    key_id = Keyword.fetch!(config, :key_id)
    app_key = Keyword.fetch!(config, :app_key)
    configured_bucket_name = Keyword.fetch!(config, :bucket_name)

    if key_id == "" or app_key == "" or configured_bucket_name == "" do
      {:error, :credentials_not_configured}
    else
      with {:ok, auth_body} <- call_authorize(key_id, app_key),
           {:ok, state} <- build_state(auth_body, configured_bucket_name) do
        Logger.info("[B2.AuthServer] Authorized. bucket_id=#{state.bucket_id}")
        {:ok, state}
      end
    end
  end

  defp call_authorize(key_id, app_key) do
    response =
      Req.get!(@authorize_url,
        auth: {:basic, "#{key_id}:#{app_key}"},
        retry: false
      )

    case response.status do
      200 ->
        {:ok, response.body}

      status ->
        Logger.error(
          "[B2.AuthServer] Authorization failed. status=#{status} code=#{inspect(response.body["code"])} message=#{inspect(response.body["message"])}"
        )

        {:error, {:b2_auth_failed, status, response.body}}
    end
  end

  defp build_state(body, configured_bucket_name) do
    storage_api = get_in(body, ["apiInfo", "storageApi"])

    api_url = storage_api["apiUrl"]
    download_url = storage_api["downloadUrl"]
    auth_token = body["authorizationToken"]
    account_id = body["accountId"]

    bucket_id_from_auth = storage_api["bucketId"]
    bucket_name_from_auth = storage_api["bucketName"]

    if bucket_id_from_auth do
      state = %__MODULE__{
        authorization_token: auth_token,
        api_url: api_url,
        download_url: download_url,
        bucket_id: bucket_id_from_auth,
        bucket_name: bucket_name_from_auth || configured_bucket_name,
        account_id: account_id
      }

      {:ok, state}
    else
      resolve_bucket_id(auth_token, api_url, download_url, account_id, configured_bucket_name)
    end
  end

  defp resolve_bucket_id(auth_token, api_url, download_url, account_id, bucket_name) do
    url =
      "#{api_url}/b2api/v3/b2_list_buckets?accountId=#{account_id}&bucketName=#{URI.encode(bucket_name)}"

    response =
      Req.get!(url,
        headers: [{"Authorization", auth_token}],
        retry: false
      )

    case response.status do
      200 ->
        buckets = get_in(response.body, ["buckets"]) || []

        case Enum.find(buckets, fn b -> b["bucketName"] == bucket_name end) do
          nil ->
            {:error, {:b2_bucket_not_found, bucket_name}}

          bucket ->
            state = %__MODULE__{
              authorization_token: auth_token,
              api_url: api_url,
              download_url: download_url,
              bucket_id: bucket["bucketId"],
              bucket_name: bucket_name,
              account_id: account_id
            }

            {:ok, state}
        end

      status ->
        {:error, {:b2_list_buckets_failed, status, response.body}}
    end
  end
end
