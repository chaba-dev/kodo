defmodule Kodo.E2E.OpenAICodexContractLiveTest do
  use ExUnit.Case, async: false

  alias Kodo.Agent.ReviewResult
  alias Kodo.Agent.Tools
  alias Kodo.LLM.ReqLLM, as: KodoReqLLM
  alias Kodo.Test.OpenAICodexContractProbe
  alias ReqLLM.Context
  alias ReqLLM.Response
  alias ReqLLM.ToolCall

  @moduletag live_provider: true, timeout: 240_000

  @model "gpt-5.4"
  @platform_model "gpt-5.4-2026-03-05"
  @timeout 180_000

  setup_all do
    auth_file =
      System.get_env("LIVE_CODEX_AUTH_FILE") ||
        flunk(
          "LIVE_CODEX_AUTH_FILE must name a private credential file from the Phase 0 device-flow spike"
        )

    auth = auth_file |> File.read!() |> Jason.decode!()

    access_token =
      fetch_secret(auth, ["access_token", "access"]) ||
        flunk("the Codex credential does not contain an access token")

    System.get_env("OPENAI_API_KEY") ||
      flunk("OPENAI_API_KEY is required to compare the Platform billing route")

    account_id =
      fetch_secret(auth, ["account_id", "accountId"]) ||
        ReqLLM.Providers.OpenAI.OAuth.account_id_from_token(access_token) ||
        flunk("the Codex credential does not contain a ChatGPT account ID")

    codex_opts =
      Keyword.merge(common_options(),
        access_token: access_token,
        chatgpt_account_id: account_id,
        auth_mode: :oauth,
        codex_originator: "kodo"
      )

    {:ok, routes: [{codex_model(), codex_opts}, {platform_model(), common_options()}]}
  end

  test "subscription route supports text with Kodo's originator", %{routes: routes} do
    opts = route_options!(routes, codex_model())

    assert {:ok, response} =
             ReqLLM.generate_text(codex_model(), "Reply with exactly KODO_CODEX_OK", opts)

    assert String.trim(Response.text(response)) == "KODO_CODEX_OK"
    assert response.model == @model
  end

  test "both billing routes support a Kodo tool call and continuation", %{routes: routes} do
    definition = Enum.find(Tools.definitions("workspace-v5"), &(&1.name == "read_file"))
    [tool] = KodoReqLLM.build_tools([definition])
    tool_choice = %{type: "function", function: %{name: "read_file"}}

    for {model, opts} <- routes do
      assert {:ok, response} =
               ReqLLM.generate_text(
                 model,
                 "Use read_file for README.md with offset 0 and limit 1.",
                 opts |> Keyword.put(:tools, [tool]) |> Keyword.put(:tool_choice, tool_choice)
               )

      assert [call] = Response.tool_calls(response)
      assert ToolCall.name(call) == "read_file"
      assert ToolCall.args_map(call) == %{"path" => "README.md", "offset" => 0, "limit" => 1}

      continued_context =
        Context.append(
          response.context,
          Context.tool_result(call.id, "read_file", "# Kodo")
        )

      assert {:ok, continued} =
               ReqLLM.generate_text(
                 model,
                 continued_context,
                 opts |> Keyword.put(:tools, []) |> Keyword.put(:tool_choice, :none)
               )

      assert String.trim(Response.text(continued)) != ""
      assert Response.tool_calls(continued) == []
    end
  end

  test "both billing routes support strict review-shaped object output", %{routes: routes} do
    for {model, opts} <- routes do
      assert {:ok, response} =
               ReqLLM.generate_object(
                 model,
                 "Return a clean review with no findings.",
                 ReviewResult.schema(),
                 Keyword.merge(opts, output_validation: :strict)
               )

      assert %{"clean" => true, "findings" => []} = Response.object(response)
    end
  end

  test "billing routes report their exact model identities", %{routes: routes} do
    prompt = "Reply with exactly KODO_IDENTITY_OK"
    codex_opts = route_options!(routes, codex_model())
    platform_opts = route_options!(routes, platform_model())

    assert {:ok, codex_response, codex_provider_model} =
             OpenAICodexContractProbe.generate_text(codex_model(), prompt, codex_opts)

    assert {:ok, platform_response} =
             ReqLLM.generate_text(platform_model(), prompt, platform_opts)

    assert String.trim(Response.text(codex_response)) == "KODO_IDENTITY_OK"
    assert String.trim(Response.text(platform_response)) == "KODO_IDENTITY_OK"
    assert codex_provider_model == @model
    assert platform_response.model == @platform_model
  end

  defp codex_model, do: "openai_codex:#{@model}"
  defp platform_model, do: "openai:#{@model}"

  defp common_options do
    [receive_timeout: @timeout, total_timeout: @timeout, max_retries: 0]
  end

  defp route_options!(routes, model) do
    {_model, opts} = List.keyfind!(routes, model, 0)
    opts
  end

  defp fetch_secret(payload, names) do
    containers = [payload, payload["tokens"]]

    Enum.find_value(containers, fn
      map when is_map(map) -> Enum.find_value(names, &Map.get(map, &1))
      _other -> nil
    end)
  end
end
