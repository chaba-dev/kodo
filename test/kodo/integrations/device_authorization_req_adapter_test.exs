defmodule Kodo.Integrations.DeviceAuthorizationReqAdapterTest do
  use ExUnit.Case, async: true

  alias Kodo.Integrations.DeviceAuthorizationReqAdapter

  test "builds origin-form request targets for every device authorization endpoint" do
    assert DeviceAuthorizationReqAdapter.request_target(
             URI.parse("https://auth.openai.com/api/accounts/deviceauth/usercode")
           ) == "/api/accounts/deviceauth/usercode"

    assert DeviceAuthorizationReqAdapter.request_target(
             URI.parse("https://auth.openai.com/api/accounts/deviceauth/token?attempt=1")
           ) == "/api/accounts/deviceauth/token?attempt=1"

    assert DeviceAuthorizationReqAdapter.request_target(
             URI.parse("https://auth.openai.com/oauth/token")
           ) == "/oauth/token"
  end
end
