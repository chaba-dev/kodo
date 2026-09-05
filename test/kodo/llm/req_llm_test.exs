defmodule Kodo.LLM.ReqLLMTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kodo.LLM.ReqLLM, as: Adapter

  @credential %Kodo.LLM.Credential{
    integration_id: "00000000-0000-0000-0000-000000000001",
    provider: "openai",
    authentication_type: "api_key",
    credential_generation: 1,
    billing_path: :platform,
    token: "request-local-key"
  }

  setup do
    previous_origins = Application.get_env(:kodo, :safe_req_test_origins)
    Application.put_env(:kodo, :safe_req_test_origins, [])

    on_exit(fn ->
      if previous_origins,
        do: Application.put_env(:kodo, :safe_req_test_origins, previous_origins),
        else: Application.delete_env(:kodo, :safe_req_test_origins)
    end)
  end

  test "translates Kodo tool definitions into strict ReqLLM tools" do
    [tool] =
      Adapter.build_tools([
        %{
          name: "read_file",
          description: "Read a bounded file range",
          parameters: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"],
            "additionalProperties" => false
          }
        }
      ])

    assert tool.name == "read_file"
    assert tool.strict
    assert tool.parameter_schema["required"] == ["path"]
  end

  test "the configured default implements the provider boundary" do
    adapter = Kodo.LLM.adapter()

    assert Code.ensure_loaded?(adapter)
    assert function_exported?(adapter, :generate, 5)
  end

  test "applies the model budget to provider receive and total timeouts" do
    options = Adapter.request_options([], timeout: 12_345, reasoning: "none")

    assert options[:receive_timeout] == 12_345
    assert options[:total_timeout] == 12_345
    assert options[:max_retries] == 0
    assert options[:telemetry] == [payloads: :none]

    assert options[:req_http_options] == [
             adapter: Kodo.LLM.SafeReqAdapter,
             redirect: false,
             redirect_log_level: false
           ]
  end

  test "overrides ambient API keys with the operation-local credential" do
    options =
      Adapter.request_options([], @credential,
        timeout: 12_345,
        reasoning: "none",
        api_key: "caller-supplied-key"
      )

    assert options[:api_key] == "request-local-key"
  end

  test "passes only current Codex access and account credentials" do
    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    options = Adapter.request_options([], credential, timeout: 12_345, reasoning: "none")

    assert options[:auth_mode] == :oauth
    assert options[:access_token] == "request-local-access"
    assert options[:chatgpt_account_id] == "request-local-account"
    refute Keyword.has_key?(options, :refresh_token)
  end

  test "rejects catalog models whose provider cannot be dispatched" do
    assert {:error, {:model_not_available, _reason}} =
             Adapter.validate_model(
               "302ai:MiniMax-M1",
               %{"reasoning" => "none"},
               Kodo.Agent.Roles.fetch!(:primary)
             )
  end

  test "uses strict tool output for GPT-5.6 models without native JSON Schema metadata" do
    for model_spec <- ~w(openai:gpt-5.6-terra openai:gpt-5.6-sol) do
      model = ReqLLM.model!(model_spec)

      refute ReqLLM.ModelHelpers.json_schema?(model)
      assert ReqLLM.Providers.OpenAI.determine_output_mode(model, []) == :tool_strict
    end
  end

  test "uses every validated ReqLLM reasoning effort in request options" do
    contract = Kodo.Agent.Roles.fetch!(:primary)

    for reasoning <- ~w(xhigh max) do
      assert {:ok, _metadata} =
               Adapter.validate_model(
                 "anthropic:claude-fable-5",
                 %{"reasoning" => reasoning},
                 contract
               )

      assert Adapter.request_options([], timeout: 100, reasoning: reasoning)[:reasoning_effort] ==
               String.to_existing_atom(reasoning)
    end
  end

  test "rejects reasoning values the adapter cannot encode" do
    assert {:error, {:unsupported_reasoning, "extreme"}} =
             Adapter.validate_model(
               "anthropic:claude-fable-5",
               %{"reasoning" => "extreme"},
               Kodo.Agent.Roles.fetch!(:primary)
             )
  end

  test "normalizes provider quota and billing errors without retaining provider bodies" do
    cases = [
      {"openai", :platform, 429, %{"error" => %{"code" => "rate_limit_exceeded"}},
       :quota_or_rate_limit, true},
      {"openai", :platform, 429,
       %{"error" => %{"code" => "credit_balance_exhausted", "message" => "secret"}},
       :billing_required, false},
      {"anthropic", :platform, 402,
       %{"error" => %{"type" => "billing_error", "message" => "secret"}}, :billing_required,
       false},
      {"openrouter", :aggregator, 402, %{"error" => %{"code" => 402, "message" => "secret"}},
       :billing_required, false},
      {"openrouter", :aggregator, 429, %{"error" => %{"code" => 429, "message" => "secret"}},
       :quota_or_rate_limit, true}
    ]

    for {provider, billing_path, status, body, expected_kind, retryable} <- cases do
      credential = %{
        @credential
        | provider: provider,
          billing_path: billing_path,
          token: "operation-local-secret"
      }

      model = LLMDB.Model.new!(%{id: "provider-model", provider: String.to_atom(provider)})

      error =
        ReqLLM.Error.API.Request.exception(
          status: status,
          reason: "provider exposed operation-local-secret",
          response_body: body
        )

      normalized = Adapter.normalize_error(error, model, credential)

      assert normalized.kind == expected_kind
      assert normalized.provider == provider
      assert normalized.billing_path == billing_path
      assert normalized.retryable == retryable
      refute inspect(normalized) =~ "operation-local-secret"
      refute inspect(normalized) =~ "secret"
    end
  end

  test "distinguishes confirmed invalid OpenAI credentials from other 401 access failures" do
    model = ReqLLM.model!("openai:gpt-4o-mini")

    invalid =
      ReqLLM.Error.API.Request.exception(
        status: 401,
        response_body: %{"error" => %{"code" => "invalid_api_key"}}
      )

    restricted = ReqLLM.Error.API.Request.exception(status: 401, response_body: %{})

    assert Adapter.normalize_error(invalid, model, @credential).kind == :authentication_rejected
    assert Adapter.normalize_error(restricted, model, @credential).kind == :access_restricted
  end

  test "classifies sanitized transport and redirect failures as retryable availability errors" do
    model = ReqLLM.model!("openai:gpt-4o-mini")

    transport =
      ReqLLM.Error.API.Request.exception(
        cause: Kodo.LLM.SafeTransportError.exception(reason: :network)
      )

    redirect = ReqLLM.Error.API.Request.exception(status: 307)

    assert %{kind: :provider_unavailable, retryable: true} =
             Adapter.normalize_error(transport, model, @credential)

    assert %{kind: :provider_unavailable, retryable: true} =
             Adapter.normalize_error(redirect, model, @credential)
  end

  test "scrubs provider errors before ReqLLM telemetry and debug logging" do
    secret = "operation-local-secret"

    server =
      start_provider_server([
        %{
          status: 401,
          body: %{
            "error" => %{
              "code" => "invalid_api_key",
              "message" => "provider echoed #{secret}"
            }
          }
        }
      ])

    handler_id = "req-llm-safe-error-#{System.unique_integer()}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:req_llm, :request, :exception],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:req_llm_exception, metadata})
        end,
        nil
      )

    previous_debug = Application.get_env(:req_llm, :debug)
    Application.put_env(:req_llm, :debug, true)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:req_llm, :debug, previous_debug)
    end)

    credential = %{@credential | token: secret}

    log =
      capture_log(fn ->
        options =
          []
          |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
          |> Keyword.put(:base_url, server.base_url)

        model = ReqLLM.model!("openai:gpt-4o-mini")

        assert {:error, error} =
                 ReqLLM.generate_text(
                   model,
                   [%{"role" => "user", "content" => "private prompt"}],
                   options
                 )

        assert Adapter.normalize_error(error, model, credential).kind ==
                 :authentication_rejected
      end)

    assert_receive {:req_llm_exception, metadata}
    refute inspect(metadata) =~ secret
    refute inspect(metadata) =~ "private prompt"
    refute log =~ secret
    refute log =~ "private prompt"
    assert [%{authorization: ["Bearer " <> ^secret]}] = provider_requests(server)
  end

  test "text and object inference reject redirects without forwarding credentials" do
    target = start_provider_server([])

    source =
      start_provider_server([
        %{status: 307, headers: [{"location", target.base_url <> "/collect"}], body: %{}},
        %{status: 307, headers: [{"location", target.base_url <> "/collect"}], body: %{}}
      ])

    model = ReqLLM.model!("openai:gpt-4o-mini")
    options = Adapter.request_options([], @credential, timeout: 5_000, reasoning: "none")

    assert {:error, text_error} =
             ReqLLM.generate_text(
               model,
               [%{"role" => "user", "content" => "hello"}],
               Keyword.put(options, :base_url, source.base_url)
             )

    assert Adapter.normalize_error(text_error, model, @credential).kind == :provider_unavailable

    assert {:error, object_error} =
             ReqLLM.generate_object(
               model,
               [%{"role" => "user", "content" => "hello"}],
               %{"type" => "object", "properties" => %{}},
               Keyword.put(options, :base_url, source.base_url)
             )

    assert Adapter.normalize_error(object_error, model, @credential).kind ==
             :provider_unavailable

    assert length(provider_requests(source)) == 2
    assert provider_requests(target) == []
  end

  test "successful Anthropic native structured output retains decoding options" do
    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "msg_test",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-3-5-haiku-latest",
            "content" => [%{"type" => "text", "text" => ~s({"answer":"ok"})}],
            "stop_reason" => "end_turn",
            "stop_sequence" => nil,
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        }
      ])

    credential = %{@credential | provider: "anthropic"}
    schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)
      |> Keyword.put(:output_validation, :strict)

    assert {:ok, response} =
             ReqLLM.generate_object(
               ReqLLM.model!("anthropic:claude-3-5-haiku-latest"),
               [%{"role" => "user", "content" => "return an answer"}],
               schema,
               options
             )

    assert ReqLLM.Response.object(response) == %{"answer" => "ok"}
  end

  test "malformed success bodies and the network boundary expose no prompt or credential telemetry" do
    secret = "malformed-response-secret"
    prompt = "private malformed-response prompt"
    server = start_provider_server([%{status: 200, body: "{echo #{secret} #{prompt}"}])
    test_pid = self()
    handler_id = "safe-boundary-#{System.unique_integer()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:finch, :request, :start], [:req_llm, :request, :exception]],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:provider_telemetry, event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    credential = %{@credential | token: secret}

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:error, _error} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai:gpt-4o-mini"),
               [%{"role" => "user", "content" => prompt}],
               options
             )

    refute_receive {:provider_telemetry, [:finch, :request, :start], _metadata}
    assert_receive {:provider_telemetry, [:req_llm, :request, :exception], metadata}
    refute inspect(metadata) =~ secret
    refute inspect(metadata) =~ prompt
  end

  test "rejects a provider-global alternate origin before dispatch" do
    server = start_provider_server([%{status: 200, body: %{}}], allow_origin?: false)
    previous = Application.get_env(:req_llm, :openai)
    Application.put_env(:req_llm, :openai, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openai, previous),
        else: Application.delete_env(:req_llm, :openai)
    end)

    assert {:error, error} =
             Adapter.generate(
               ReqLLM.model!("openai:gpt-4o-mini"),
               [%{"role" => "user", "content" => "private prompt"}],
               [],
               @credential,
               timeout: 5_000,
               reasoning: "none"
             )

    assert error.kind == :request_failed
    assert provider_requests(server) == []
  end

  test "reconstructs a tool exchange from provider-independent persisted values" do
    context =
      Adapter.build_context([
        %{"role" => "system", "content" => "system"},
        %{"role" => "user", "content" => "inspect"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call-1",
              "name" => "read_file",
              "arguments" => %{"path" => "mix.exs"}
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call-1",
          "name" => "read_file",
          "content" => %{"content" => "project", "truncated" => false}
        }
      ])

    assert [system, user, assistant, result] = context.messages
    assert system.role == :system
    assert user.role == :user
    assert [%{id: "call-1"}] = assistant.tool_calls
    assert result.role == :tool
    assert result.tool_call_id == "call-1"
    assert result.name == "read_file"
  end

  test "reconstructs reasoning continuity and provider tool metadata" do
    tool_call =
      "call-1"
      |> ReqLLM.ToolCall.new("read_file", ~s({"path":"mix.exs"}))
      |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "signed-call"})

    message = %ReqLLM.Message{
      role: :assistant,
      content: [
        ReqLLM.Message.ContentPart.thinking("checking"),
        ReqLLM.Message.ContentPart.text("answer", %{index: 1})
      ],
      metadata: %{
        response_id: "response-1",
        phase: "final_answer",
        phase_items: [%{"phase" => "final_answer", "content" => []}]
      },
      reasoning_details: [
        %ReqLLM.Message.ReasoningDetails{
          text: nil,
          signature: "encrypted-reasoning",
          encrypted?: true,
          provider: :google,
          format: "thought_signature",
          index: 0,
          provider_data: %{"opaque" => "value"}
        }
      ],
      tool_calls: [tool_call]
    }

    provider_state =
      message
      |> Adapter.dump_assistant("answer", [tool_call])
      |> Jason.encode!()
      |> Jason.decode!()

    context =
      Adapter.build_context([
        %{"role" => "assistant", "provider_state" => provider_state}
      ])

    assert [assistant] = context.messages
    assert assistant.content == message.content
    assert assistant.metadata == message.metadata

    assert [%{signature: "encrypted-reasoning", provider: :google}] =
             assistant.reasoning_details

    assert [restored_tool_call] = assistant.tool_calls
    assert restored_tool_call == tool_call
  end

  defp start_provider_server(responses, opts \\ []) do
    port = free_port()

    agent =
      start_supervised!(
        {Agent, fn -> %{requests: [], responses: responses} end},
        id: {:provider_http_state, port}
      )

    start_supervised!(
      {Bandit,
       plug: {Kodo.Test.ProviderHTTPPlug, agent},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1},
       startup_log: false},
      id: {:provider_http, port}
    )

    server = %{agent: agent, base_url: "http://127.0.0.1:#{port}"}
    origin = {"http", "127.0.0.1", port}

    if Keyword.get(opts, :allow_origin?, true) do
      Application.put_env(:kodo, :safe_req_test_origins, [origin | test_origins()])
    end

    server
  end

  defp test_origins, do: Application.get_env(:kodo, :safe_req_test_origins, [])

  defp provider_requests(server), do: Agent.get(server.agent, & &1.requests)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
