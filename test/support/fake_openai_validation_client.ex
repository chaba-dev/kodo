defmodule Kodo.Test.FakeOpenAIValidationClient do
  @moduledoc false

  @behaviour Kodo.Integrations.OpenAIValidationClient

  @impl true
  def get_models("valid-" <> _rest), do: {:ok, 200, %{"data" => []}}

  def get_models("invalid-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "invalid_api_key"}}}

  def get_models("permission-" <> _rest),
    do: {:ok, 401, %{"error" => %{"code" => "organization_restricted"}}}

  def get_models("timeout-" <> _rest), do: {:error, :timeout}
  def get_models(_api_key), do: {:error, :network_error}
end
