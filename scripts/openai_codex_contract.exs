Mix.Task.run("app.config")
Application.ensure_all_started(:req)

defmodule Kodo.OpenAICodexContractSpike do
  @moduledoc false

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @issuer "https://auth.openai.com"
  @verification_url "https://auth.openai.com/codex/device"
  @redirect_uri "https://auth.openai.com/deviceauth/callback"
  @deadline_seconds 15 * 60

  def authorize(path) do
    response = post_json!("#{@issuer}/api/accounts/deviceauth/usercode", %{client_id: @client_id})
    device_auth_id = fetch_string!(response, "device_auth_id")
    user_code = fetch_string!(response, ["user_code", "usercode"])
    interval = response |> fetch_string!("interval") |> String.to_integer()

    IO.puts("Open #{@verification_url} and enter this one-time code within 15 minutes:")
    IO.puts(user_code)

    poll_response = poll(device_auth_id, user_code, interval)

    exchange =
      post_form!("#{@issuer}/oauth/token", %{
        grant_type: "authorization_code",
        code: fetch_string!(poll_response, "authorization_code"),
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: fetch_string!(poll_response, "code_verifier")
      })

    credential = %{
      "access_token" => fetch_string!(exchange, "access_token"),
      "refresh_token" => fetch_string!(exchange, "refresh_token"),
      "id_token" => fetch_string!(exchange, "id_token"),
      "account_id" => account_id(exchange),
      "expires_at" => jwt_expiry(exchange["access_token"]),
      "obtained_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    persist!(path, credential)
    IO.puts("Device authorization succeeded; private credentials written to #{path}")
  end

  def refresh(path) do
    credential = path |> File.read!() |> Jason.decode!()
    prior_refresh_token = credential["refresh_token"]

    response =
      post_json!("#{@issuer}/oauth/token", %{
        client_id: @client_id,
        grant_type: "refresh_token",
        refresh_token: fetch_string!(credential, "refresh_token")
      })

    refreshed =
      credential
      |> replace_if_present(response, "access_token")
      |> replace_if_present(response, "refresh_token")
      |> replace_if_present(response, "id_token")
      |> Map.put("expires_at", jwt_expiry(response["access_token"] || credential["access_token"]))
      |> Map.put("account_id", account_id(response, credential["account_id"]))
      |> Map.put(
        "refreshed_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    persist!(path, refreshed)

    rotation =
      case response["refresh_token"] do
        nil ->
          "omitted a refresh token, so the prior token was preserved"

        replacement when replacement == prior_refresh_token ->
          "returned the same refresh token"

        _replacement ->
          "rotated the refresh token"
      end

    IO.puts("Refresh succeeded and #{rotation}; private credentials updated at #{path}")
  end

  defp poll(device_auth_id, user_code, interval) do
    deadline = System.monotonic_time(:second) + @deadline_seconds
    do_poll(device_auth_id, user_code, interval, deadline)
  end

  defp do_poll(device_auth_id, user_code, interval, deadline) do
    response =
      Req.post!(
        url: "#{@issuer}/api/accounts/deviceauth/token",
        json: %{device_auth_id: device_auth_id, user_code: user_code},
        redirect: false,
        retry: false
      )

    cond do
      response.status in 200..299 ->
        ensure_map!(response.body)

      response.status in [403, 404] and System.monotonic_time(:second) < deadline ->
        remaining = deadline - System.monotonic_time(:second)
        Process.sleep(min(interval, remaining) * 1000)
        do_poll(device_auth_id, user_code, interval, deadline)

      response.status in [403, 404] ->
        raise "device authorization timed out after #{@deadline_seconds} seconds"

      true ->
        raise "device authorization polling failed with HTTP #{response.status}"
    end
  end

  defp post_json!(url, body) do
    response = Req.post!(url: url, json: body, redirect: false, retry: false)
    ensure_success!(response)
  end

  defp post_form!(url, body) do
    response = Req.post!(url: url, form: body, redirect: false, retry: false)
    ensure_success!(response)
  end

  defp ensure_success!(%Req.Response{status: status, body: body}) when status in 200..299,
    do: ensure_map!(body)

  defp ensure_success!(%Req.Response{status: status}) do
    raise "OpenAI authorization request failed with HTTP #{status}"
  end

  defp ensure_map!(body) when is_map(body), do: body

  defp ensure_map!(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> raise "OpenAI authorization response was not a JSON object"
    end
  end

  defp fetch_string!(map, names) when is_list(names) do
    Enum.find_value(names, &Map.get(map, &1)) ||
      raise "OpenAI authorization response omitted #{Enum.join(names, " or ")}"
  end

  defp fetch_string!(map, name), do: fetch_string!(map, [name])

  defp replace_if_present(existing, update, key) do
    case update[key] do
      value when is_binary(value) and value != "" -> Map.put(existing, key, value)
      _other -> existing
    end
  end

  defp account_id(tokens, fallback \\ nil) do
    jwt_claim(tokens["id_token"] || tokens["access_token"], [
      "https://api.openai.com/auth",
      "chatgpt_account_id"
    ]) || fallback || raise "OpenAI tokens omitted the ChatGPT account ID claim"
  end

  defp jwt_expiry(token) do
    case jwt_claim(token, ["exp"]) do
      expiry when is_integer(expiry) -> expiry * 1000
      _other -> nil
    end
  end

  defp jwt_claim(token, path) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      get_in(claims, path)
    else
      _other -> nil
    end
  end

  defp jwt_claim(_token, _path), do: nil

  defp persist!(path, credential) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, Jason.encode_to_iodata!(credential, pretty: true), [:exclusive])
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
  end
end

case System.argv() do
  ["authorize", path] ->
    Kodo.OpenAICodexContractSpike.authorize(path)

  ["refresh", path] ->
    Kodo.OpenAICodexContractSpike.refresh(path)

  _other ->
    IO.puts(
      :stderr,
      "Usage: mix run --no-start scripts/openai_codex_contract.exs authorize|refresh PATH"
    )

    System.halt(2)
end
