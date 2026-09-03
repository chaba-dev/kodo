defmodule KodoWeb.ParameterFilteringTest do
  use ExUnit.Case, async: true

  test "redacts provider credentials and credential-derived identifiers recursively" do
    secret_fields = [
      "token",
      "api_key",
      "access_token",
      "refresh_token",
      "id_token",
      "device_code",
      "user_code",
      "client_secret",
      "authorization",
      "encrypted_credentials",
      "account_id",
      "chatgpt_account_id",
      "organization_id",
      "workspace_id"
    ]

    params = %{
      "integration" => Map.new(secret_fields, &{&1, "provider-secret-#{&1}"}),
      "provider" => "openai"
    }

    filtered = Phoenix.Logger.filter_values(params)

    assert filtered["provider"] == "openai"

    for field <- secret_fields do
      assert filtered["integration"][field] == "[FILTERED]"
      refute inspect(filtered) =~ "provider-secret-#{field}"
    end
  end
end
