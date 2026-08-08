defmodule Kodo.RunnersTest do
  use Kodo.DataCase

  alias Kodo.Runners

  @valid %{
    workspace_root: "/work/project",
    platform: "linux",
    architecture: "x86_64",
    runner_version: "0.1.0",
    protocol_version: 3,
    capabilities: ["shell"]
  }

  test "registration upserts the reported workspace identity with a stable id" do
    assert {:ok, first} = Runners.register(@valid)
    assert {:ok, second} = Runners.register(%{@valid | runner_version: "0.2.0"})
    assert first.id == second.id
    assert second.runner_version == "0.2.0"
  end

  test "registration rejects unsupported protocol versions" do
    assert {:error, changeset} = Runners.register(%{@valid | protocol_version: 1})
    assert "must be equal to 3" in errors_on(changeset).protocol_version
  end

  test "dispatch rejects payloads that cannot fit in a complete wire message" do
    payload = %{"content" => String.duplicate("x", 4 * 1024 * 1024)}

    assert {:error, :invalid_request} = Runners.dispatch(Ecto.UUID.generate(), payload)
  end
end
