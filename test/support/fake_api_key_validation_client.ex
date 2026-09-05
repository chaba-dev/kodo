defmodule Kodo.Test.FakeAPIKeyValidationClient do
  @moduledoc false

  @behaviour Kodo.Integrations.APIKeyValidationClient

  @impl true
  def get_metadata(provider, "valid-" <> _rest) when provider in ~w(openai anthropic),
    do: {:ok, 200, %{"data" => []}}

  def get_metadata("openrouter", "valid-" <> _rest),
    do: {:ok, 200, %{"data" => %{}}}

  def get_metadata("openai", "invalid-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "invalid_api_key"}}}

  def get_metadata("openai", "revoked-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "key_revoked"}}}

  def get_metadata("anthropic", "invalid-" <> _rest),
    do: {:ok, 401, %{"error" => %{"type" => "authentication_error"}}}

  def get_metadata("anthropic", "workspace-required-" <> _rest),
    do: {:ok, 400, %{"error" => %{"type" => "invalid_request_error"}}}

  def get_metadata("openrouter", "invalid-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => 401}}}

  def get_metadata("openai", "permission-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "organization_restricted"}}}

  def get_metadata(_provider, "permission-" <> _rest), do: {:ok, 403, %{}}
  def get_metadata(_provider, "timeout-" <> _rest), do: {:error, :timeout}
  def get_metadata(_provider, "tls-" <> _rest), do: {:error, :tls_error}
  def get_metadata(_provider, "redirect-" <> _rest), do: {:error, :redirect}
  def get_metadata(_provider, "rate-limited-" <> _rest), do: {:ok, 429, %{}}
  def get_metadata(_provider, "provider-error-" <> _rest), do: {:ok, 503, %{}}

  def get_metadata(_provider, "raising-" <> secret) do
    raise "validation client exposed #{secret}"
  end

  def get_metadata(_provider, "blocking-" <> _rest) do
    test_pid = Application.fetch_env!(:kodo, :fake_api_key_validation_test_pid)
    [caller | _callers] = Process.get(:"$callers")
    send(test_pid, {:validation_probe_started, self(), caller})

    receive do
      {:finish_validation_probe, result} -> result
    end
  end

  def get_metadata(_provider, _api_key), do: {:error, :network_error}
end
