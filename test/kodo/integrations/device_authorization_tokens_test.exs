defmodule Kodo.Integrations.DeviceAuthorizationTokensTest do
  use ExUnit.Case, async: true

  alias Kodo.Integrations.DeviceAuthorizationTokens

  @now ~U[2026-09-10 12:00:00Z]

  test "normalizes required tokens, account identity, and access-token expiry" do
    tokens = %{
      "access_token" => jwt(%{"exp" => DateTime.to_unix(@now) + 3_600}),
      "refresh_token" => "refresh-secret",
      "id_token" =>
        jwt(%{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-secret"}
        })
    }

    assert {:ok, normalized} = DeviceAuthorizationTokens.normalize(tokens, @now)
    assert DateTime.to_unix(normalized.expires_at) == DateTime.to_unix(@now) + 3_600

    assert normalized.credentials ==
             Map.put(tokens, "account_id", "account-secret")
  end

  test "rejects missing identity, malformed tokens, and non-future expiration" do
    valid_identity =
      jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "account"}})

    invalid_tokens = [
      %{
        "access_token" => jwt(%{"exp" => DateTime.to_unix(@now)}),
        "refresh_token" => "refresh",
        "id_token" => valid_identity
      },
      %{
        "access_token" => "not-a-jwt",
        "refresh_token" => "refresh",
        "id_token" => valid_identity
      },
      %{
        "access_token" => jwt(%{"exp" => DateTime.to_unix(@now) + 60}),
        "refresh_token" => "refresh",
        "id_token" => jwt(%{"https://api.openai.com/auth" => %{}})
      },
      %{
        "access_token" => jwt(%{"exp" => DateTime.to_unix(@now) + 60}),
        "refresh_token" => "refresh"
      }
    ]

    for tokens <- invalid_tokens do
      assert {:error, :device_authorization_response_invalid} =
               DeviceAuthorizationTokens.normalize(tokens, @now)
    end
  end

  defp jwt(claims) do
    encoded = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded}.signature"
  end
end
