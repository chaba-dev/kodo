defmodule Kodo.Test.FakeOpenAIValidationClient do
  @moduledoc false

  @behaviour Kodo.Integrations.OpenAIValidationClient

  @impl true
  def get_models("valid-" <> _rest), do: {:ok, 200, %{"data" => []}}

  def get_models("invalid-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "invalid_api_key"}}}

  def get_models("revoked-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "key_revoked"}}}

  def get_models("permission-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "organization_restricted"}}}

  def get_models("timeout-" <> _rest), do: {:error, :timeout}
  def get_models("tls-" <> _rest), do: {:error, :tls_error}
  def get_models("redirect-" <> _rest), do: {:error, :redirect}
  def get_models("rate-limited-" <> _rest), do: {:ok, 429, %{}}
  def get_models("provider-error-" <> _rest), do: {:ok, 503, %{}}

  def get_models("blocking-" <> _rest) do
    test_pid = Application.fetch_env!(:kodo, :fake_openai_validation_test_pid)
    send(test_pid, {:validation_probe_started, self()})

    receive do
      {:finish_validation_probe, result} -> result
    end
  end

  def get_models(_api_key), do: {:error, :network_error}
end
