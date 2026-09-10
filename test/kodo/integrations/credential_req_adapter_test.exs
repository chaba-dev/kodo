defmodule Kodo.Integrations.CredentialReqAdapterTest do
  use ExUnit.Case, async: true

  alias Kodo.Integrations.CredentialReqAdapter

  test "builds origin-form request targets for every device authorization endpoint" do
    assert CredentialReqAdapter.request_target(
             URI.parse("https://auth.openai.com/api/accounts/deviceauth/usercode")
           ) == "/api/accounts/deviceauth/usercode"

    assert CredentialReqAdapter.request_target(
             URI.parse("https://auth.openai.com/api/accounts/deviceauth/token?attempt=1")
           ) == "/api/accounts/deviceauth/token?attempt=1"

    assert CredentialReqAdapter.request_target(URI.parse("https://auth.openai.com/oauth/token")) ==
             "/oauth/token"
  end
end
