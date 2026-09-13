defmodule Kodo.Integrations.RefreshTokensTest do
  use ExUnit.Case, async: true

  alias Kodo.Integrations.RefreshTokens

  test "requires a future access expiry and retains omitted rotated fields" do
    now = ~U[2026-09-10 05:00:00.000000Z]
    current = current_tokens()

    assert {:ok, normalized} =
             RefreshTokens.normalize(
               %{"access_token" => jwt(%{"exp" => DateTime.to_unix(now) + 60})},
               current,
               now
             )

    assert normalized.credentials["refresh_token"] == current["refresh_token"]
    assert normalized.credentials["id_token"] == current["id_token"]
    assert normalized.credentials["account_id"] == "account"
    assert normalized.expires_at == ~U[2026-09-10 05:01:00.000000Z]

    assert {:error, :oauth_refresh_response_invalid} =
             RefreshTokens.normalize(
               %{"access_token" => jwt(%{"exp" => DateTime.to_unix(now)})},
               current,
               now
             )
  end

  test "persists rotated refresh and identity tokens without changing billing identity" do
    now = ~U[2026-09-10 05:00:00.000000Z]
    rotated_id = id_token("account")

    assert {:ok, normalized} =
             RefreshTokens.normalize(
               %{
                 "access_token" => jwt(%{"exp" => DateTime.to_unix(now) + 60}),
                 "refresh_token" => "rotated-refresh",
                 "id_token" => rotated_id
               },
               current_tokens(),
               now
             )

    assert normalized.credentials["refresh_token"] == "rotated-refresh"
    assert normalized.credentials["id_token"] == rotated_id
  end

  test "rejects an account identity change and malformed returned identity token" do
    response = %{
      "access_token" => jwt(%{"exp" => DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(60)}),
      "id_token" => id_token("other-account")
    }

    assert {:error, :refresh_account_identity_mismatch} =
             RefreshTokens.normalize(response, current_tokens())

    assert {:error, :oauth_refresh_response_invalid} =
             RefreshTokens.normalize(
               %{response | "id_token" => "malformed"},
               current_tokens()
             )
  end

  defp current_tokens do
    %{
      "access_token" => "old-access",
      "refresh_token" => "old-refresh",
      "id_token" => id_token("account"),
      "account_id" => "account"
    }
  end

  defp id_token(account_id) do
    jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}})
  end

  defp jwt(claims) do
    encoded = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded}.signature"
  end
end
