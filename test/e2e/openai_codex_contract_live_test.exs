defmodule Kodo.E2E.OpenAICodexContractLiveTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Response
  alias ReqLLM.Tool
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

    codex_opts = [
      access_token: access_token,
      chatgpt_account_id: account_id,
      auth_mode: :oauth,
      codex_originator: "kodo",
      receive_timeout: @timeout,
      total_timeout: @timeout
    ]

    {:ok, routes: [{codex_model(), codex_opts}, {platform_model(), []}]}
  end

  test "subscription route supports text with Kodo's originator", %{routes: routes} do
    opts = route_options!(routes, codex_model())

    assert {:ok, response} =
             ReqLLM.generate_text(codex_model(), "Reply with exactly KODO_CODEX_OK", opts)

    assert Response.text(response) == "KODO_CODEX_OK"
    assert response.model == @model
  end

  test "both billing routes support a Kodo tool call and continuation", %{routes: routes} do
    tool =
      Tool.new!(
        name: "add_integers",
        description: "Add two integers",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "left" => %{"type" => "integer"},
            "right" => %{"type" => "integer"}
          },
          "required" => ["left", "right"],
          "additionalProperties" => false
        },
        callback: fn _arguments -> {:error, :not_executed_by_spike} end,
        strict: true
      )

    for {model, opts} <- routes do
      assert {:ok, response} =
               ReqLLM.generate_text(
                 model,
                 "Use add_integers to add 20 and 22. Do not calculate it yourself.",
                 Keyword.put(opts, :tools, [tool])
               )

      assert [call] = Response.tool_calls(response)
      assert ToolCall.name(call) == "add_integers"
      assert ToolCall.args_map(call) == %{"left" => 20, "right" => 22}

      continued_context =
        Context.append(
          response.context,
          Context.tool_result(call.id, "add_integers", "42")
        )

      assert {:ok, continued} =
               ReqLLM.generate_text(model, continued_context, Keyword.put(opts, :tools, [tool]))

      assert Response.text(continued) =~ "42"
      assert Response.tool_calls(continued) == []
    end
  end

  test "both billing routes support strict review-shaped object output", %{routes: routes} do
    schema = [
      verdict: [type: {:in, ["pass"]}, required: true],
      summary: [type: :string, required: true]
    ]

    for {model, opts} <- routes do
      assert {:ok, response} =
               ReqLLM.generate_object(
                 model,
                 "Return a passing review with a short summary.",
                 schema,
                 Keyword.merge(opts, output_validation: :strict)
               )

      assert %{"verdict" => "pass", "summary" => summary} = Response.object(response)
      assert is_binary(summary) and summary != ""
    end
  end

  test "billing routes report their exact model identities", %{routes: routes} do
    prompt = "Reply with exactly KODO_IDENTITY_OK"
    codex_opts = route_options!(routes, codex_model())

    assert {:ok, codex_response} = ReqLLM.generate_text(codex_model(), prompt, codex_opts)

    assert {:ok, platform_response} =
             ReqLLM.generate_text(platform_model(), prompt,
               receive_timeout: @timeout,
               total_timeout: @timeout
             )

    assert Response.text(codex_response) == "KODO_IDENTITY_OK"
    assert Response.text(platform_response) == "KODO_IDENTITY_OK"
    assert codex_response.model == @model
    assert platform_response.model == @platform_model
  end

  defp codex_model, do: "openai_codex:#{@model}"
  defp platform_model, do: "openai:#{@model}"

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
