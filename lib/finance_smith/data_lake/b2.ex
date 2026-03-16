defmodule FinanceSmith.DataLake.B2 do
  @moduledoc """
  Stateless B2 native API client.

  All functions obtain credentials from `B2.AuthServer` and automatically
  trigger a token refresh + single retry on `401 Unauthorized` responses.

  Upload flow: `b2_get_upload_url` -> `b2_upload_file`
  Download flow: `b2_download_file_by_name` (streamed into memory per NFR-2.2)
  """

  alias FinanceSmith.DataLake.B2.AuthServer

  require Logger

  @doc """
  Uploads `content` (binary) to B2 under the given `file_name`.

  Returns `{:ok, file_id}` on success or `{:error, reason}` on failure.
  """
  @spec upload_file(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def upload_file(file_name, content) do
    with {:ok, auth} <- AuthServer.get_auth() do
      do_upload(auth, file_name, content, retry: true)
    end
  end

  @doc """
  Downloads a file from B2 by its object key and returns the content as a binary.

  The response body is collected fully into memory. Files are downloaded one at a
  time per Broadway message (bounded by visibility timeout), preventing unbounded
  memory accumulation across concurrent messages.

  Returns `{:ok, binary()}` or `{:error, reason}`.
  """
  @spec download_file(String.t()) :: {:ok, binary()} | {:error, term()}
  def download_file(file_name) do
    with {:ok, auth} <- AuthServer.get_auth() do
      do_download(auth, file_name, retry: true)
    end
  end

  # --- Upload helpers -------------------------------------------------------

  defp do_upload(auth, file_name, content, retry: retry) when is_boolean(retry) do
    with {:ok, upload_url, upload_token} <- get_upload_url(auth) do
      sha1 = :crypto.hash(:sha, content) |> Base.encode16(case: :lower)
      byte_count = byte_size(content)

      response =
        Req.post!(upload_url,
          headers: [
            {"Authorization", upload_token},
            {"X-Bz-File-Name", URI.encode(file_name)},
            {"Content-Type", "application/json"},
            {"Content-Length", Integer.to_string(byte_count)},
            {"X-Bz-Content-Sha1", sha1}
          ],
          body: content,
          retry: false
        )

      case response.status do
        200 ->
          {:ok, response.body["fileId"]}

        401 when retry ->
          Logger.warning("[B2] Upload 401 — refreshing token and retrying. file=#{file_name}")
          :ok = AuthServer.refresh()
          {:ok, fresh_auth} = AuthServer.get_auth()
          do_upload(fresh_auth, file_name, content, retry: false)

        status ->
          Logger.error(
            "[B2] Upload failed. status=#{status} file=#{file_name} body=#{inspect(response.body)}"
          )

          {:error, {:b2_upload_failed, status, response.body}}
      end
    end
  end

  defp get_upload_url(auth) do
    response =
      Req.post!("#{auth.api_url}/b2api/v3/b2_get_upload_url",
        headers: [{"Authorization", auth.authorization_token}],
        json: %{bucketId: auth.bucket_id},
        retry: false
      )

    case response.status do
      200 ->
        {:ok, response.body["uploadUrl"], response.body["authorizationToken"]}

      status ->
        {:error, {:b2_get_upload_url_failed, status, response.body}}
    end
  end

  # --- Download helpers -----------------------------------------------------

  defp do_download(auth, file_name, retry: retry) when is_boolean(retry) do
    url = "#{auth.download_url}/file/#{auth.bucket_name}/#{URI.encode(file_name)}"

    response =
      Req.get!(url,
        headers: [{"Authorization", auth.authorization_token}],
        retry: false
      )

    case response.status do
      200 ->
        {:ok, response.body}

      401 when retry ->
        Logger.warning("[B2] Download 401 — refreshing token and retrying. file=#{file_name}")
        :ok = AuthServer.refresh()
        {:ok, fresh_auth} = AuthServer.get_auth()
        do_download(fresh_auth, file_name, retry: false)

      404 ->
        {:error, {:b2_file_not_found, file_name}}

      status ->
        Logger.error(
          "[B2] Download failed. status=#{status} file=#{file_name} body=#{inspect(response.body)}"
        )

        {:error, {:b2_download_failed, status, response.body}}
    end
  end
end
