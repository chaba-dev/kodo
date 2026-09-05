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
              "type" => "invalid_request_error",
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
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => 1,
              "cache_read_input_tokens" => 1_000,
              "cache_creation_input_tokens" => 500
            }
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
    assert response.usage.cached_tokens == 1_000
    assert response.usage.cache_creation_tokens == 500
  end

  test "successful provider usage cannot create unbounded telemetry keys" do
    secret = "usage-key-secret"
    prompt = "private usage-key prompt"

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "resp_test",
            "object" => "response",
            "model" => "gpt-4o-mini",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => "ok", "annotations" => []}
                ]
              }
            ],
            "usage" => %{
              "input_tokens" => 1,
              "output_tokens" => 1,
              "server_side_tool_usage_details" => %{
                "web_search_calls" => 1,
                "#{secret} #{prompt}_calls" => 1
              }
            }
          }
        }
      ])

    test_pid = self()
    handler_id = "safe-success-telemetry-#{System.unique_integer()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:req_llm, :token_usage], [:req_llm, :request, :stop]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:success_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    options =
      []
      |> Adapter.request_options(@credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:ok, response} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai:gpt-4o-mini"),
               [%{"role" => "user", "content" => prompt}],
               options
             )

    assert ReqLLM.Response.text(response) == "ok"

    assert_receive {:success_telemetry, [:req_llm, :token_usage], measurements, metadata}
    refute inspect({measurements, metadata}) =~ secret
    refute inspect({measurements, metadata}) =~ prompt

    assert_receive {:success_telemetry, [:req_llm, :request, :stop], measurements, metadata}
    refute inspect({measurements, metadata}) =~ secret
    refute inspect({measurements, metadata}) =~ prompt
  end

  test "rejects unsafe decoded usage before telemetry or persistence" do
    secret = "decoded-usage-secret"
    prompt = "private decoded-usage prompt"
    test_pid = self()
    handler_id = "safe-decoded-usage-#{System.unique_integer()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:req_llm, :token_usage], [:req_llm, :request, :stop], [:req_llm, :request, :exception]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:decoded_usage_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    cases = [
      {
        ReqLLM.model!("openai:gpt-4o-mini"),
        @credential,
        %{
          "id" => "resp_unsafe",
          "object" => "response",
          "model" => "gpt-4o-mini",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "ok", "annotations" => []}]
            },
            %{"type" => "#{secret} #{prompt}_call"}
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }
      },
      {
        ReqLLM.model!("openrouter:anthropic/claude-sonnet-4"),
        %{@credential | provider: "openrouter", billing_path: :aggregator},
        %{
          "id" => "chat_unsafe",
          "model" => "anthropic/claude-sonnet-4",
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "ok"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 1,
            "completion_tokens" => 1,
            "total_tokens" => 2,
            "tool_usage" => %{
              "#{secret} #{prompt}" => %{"count" => 1, "unit" => "private-detail"}
            }
          }
        }
      },
      {
        ReqLLM.model!("openrouter:anthropic/claude-sonnet-4"),
        %{@credential | provider: "openrouter", billing_path: :aggregator},
        %{
          "id" => "chat_bad_total",
          "model" => "anthropic/claude-sonnet-4",
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "ok"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 1,
            "completion_tokens" => 1,
            "total_tokens" => "#{secret} #{prompt}"
          }
        }
      }
    ]

    for {model, credential, body} <- cases do
      server = start_provider_server([%{status: 200, body: body}])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      log =
        capture_log(fn ->
          assert {:error, error} =
                   ReqLLM.generate_text(
                     model,
                     [%{"role" => "user", "content" => prompt}],
                     options
                   )

          refute inspect(error) =~ secret
          refute inspect(error) =~ prompt
        end)

      assert_receive {:decoded_usage_telemetry, [:req_llm, :request, :exception], measurements,
                      metadata}

      refute inspect({measurements, metadata}) =~ secret
      refute inspect({measurements, metadata}) =~ prompt
      refute log =~ secret
      refute log =~ prompt
      refute_receive {:decoded_usage_telemetry, [:req_llm, :token_usage], _, _}
      refute_receive {:decoded_usage_telemetry, [:req_llm, :request, :stop], _, _}
    end
  end

  test "rejects credentials reconstructed from nested tool argument JSON" do
    secret = "request-local-key"

    escaped_arguments =
      ~S({"path":"\u0072equest-local-key","\u0072equest-local-key":"echo"})

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "chat_escaped_key",
            "model" => "anthropic/claude-sonnet-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "call-1",
                      "type" => "function",
                      "function" => %{
                        "name" => "read_file",
                        "arguments" => escaped_arguments
                      }
                    }
                  ]
                },
                "finish_reason" => "tool_calls"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        }
      ])

    previous = Application.get_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openrouter, previous),
        else: Application.delete_env(:req_llm, :openrouter)
    end)

    credential = %{@credential | provider: "openrouter", billing_path: :aggregator}

    assert {:error, %Kodo.LLM.ProviderError{kind: :request_failed} = error} =
             Adapter.generate(
               ReqLLM.model!("openrouter:anthropic/claude-sonnet-4"),
               [%{"role" => "user", "content" => "use read_file"}],
               [],
               credential,
               timeout: 5_000,
               reasoning: "none"
             )

    refute inspect(error) =~ secret
  end

  test "rejects credentials reconstructed by tool argument JSON repair" do
    secret = "request-local-key"
    arguments = ~S({"path":"\u0072equest-local-key",})

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "chat_repaired_key",
            "model" => "anthropic/claude-sonnet-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "call-1",
                      "type" => "function",
                      "function" => %{"name" => "read_file", "arguments" => arguments}
                    }
                  ]
                },
                "finish_reason" => "tool_calls"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        }
      ])

    previous = Application.get_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openrouter, previous),
        else: Application.delete_env(:req_llm, :openrouter)
    end)

    credential = %{@credential | provider: "openrouter", billing_path: :aggregator}

    assert {:error, %Kodo.LLM.ProviderError{kind: :request_failed} = error} =
             Adapter.generate(
               ReqLLM.model!("openrouter:anthropic/claude-sonnet-4"),
               [%{"role" => "user", "content" => "use read_file"}],
               [],
               credential,
               timeout: 5_000,
               reasoning: "none"
             )

    refute inspect(error) =~ secret
  end

  test "rejects provider objects in decoded tool call IDs" do
    private_detail = "private-provider-detail"

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "chat_bad_call_id",
            "model" => "anthropic/claude-sonnet-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => %{"request_dump" => private_detail},
                      "type" => "function",
                      "function" => %{"name" => "read_file", "arguments" => "{}"}
                    }
                  ]
                },
                "finish_reason" => "tool_calls"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        }
      ])

    previous = Application.get_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openrouter, previous),
        else: Application.delete_env(:req_llm, :openrouter)
    end)

    credential = %{@credential | provider: "openrouter", billing_path: :aggregator}

    assert {:error, %Kodo.LLM.ProviderError{kind: :request_failed} = error} =
             Adapter.generate(
               ReqLLM.model!("openrouter:anthropic/claude-sonnet-4"),
               [%{"role" => "user", "content" => "use read_file"}],
               [],
               credential,
               timeout: 5_000,
               reasoning: "none"
             )

    refute inspect(error) =~ private_detail
  end

  test "rejects credentials reconstructed from sibling text parts" do
    secret = "request-local-key"

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "chat_split_key",
            "model" => "anthropic/claude-sonnet-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => [
                    %{"type" => "text", "text" => "request-local-"},
                    %{"type" => "text", "text" => "key"}
                  ]
                },
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        },
        %{
          status: 200,
          body: %{
            "id" => "chat_safe_parts",
            "model" => "anthropic/claude-sonnet-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => [
                    %{"type" => "text", "text" => "safe "},
                    %{"type" => "text", "text" => "answer"}
                  ]
                },
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        }
      ])

    previous = Application.get_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openrouter, previous),
        else: Application.delete_env(:req_llm, :openrouter)
    end)

    credential = %{@credential | provider: "openrouter", billing_path: :aggregator}
    model = ReqLLM.model!("openrouter:anthropic/claude-sonnet-4")

    assert {:error, %Kodo.LLM.ProviderError{kind: :request_failed} = error} =
             Adapter.generate(model, [%{"role" => "user", "content" => "answer"}], [], credential,
               timeout: 5_000,
               reasoning: "none"
             )

    refute inspect(error) =~ secret

    assert {:ok, %{text: "safe answer"}} =
             Adapter.generate(model, [%{"role" => "user", "content" => "answer"}], [], credential,
               timeout: 5_000,
               reasoning: "none"
             )
  end

  test "persists only reviewed OpenRouter reasoning continuation fields" do
    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "chat_reasoning",
            "model" => "anthropic/claude-sonnet-4",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => "answer",
                  "reasoning_details" => [
                    %{
                      "type" => "reasoning.text",
                      "text" => "Checking the result.",
                      "signature" => "signed-reasoning",
                      "id" => "reasoning-1",
                      "format" => "anthropic-claude-v1",
                      "index" => 0,
                      "debug" => %{
                        "request_dump" => "private-provider-detail",
                        "arbitrary_field" => "unreviewed metadata"
                      }
                    }
                  ]
                },
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }
        }
      ])

    previous = Application.get_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openrouter, previous),
        else: Application.delete_env(:req_llm, :openrouter)
    end)

    credential = %{@credential | provider: "openrouter", billing_path: :aggregator}

    assert {:ok, %{assistant: assistant}} =
             Adapter.generate(
               ReqLLM.model!("openrouter:anthropic/claude-sonnet-4"),
               [%{"role" => "user", "content" => "answer"}],
               [],
               credential,
               timeout: 5_000,
               reasoning: "none"
             )

    assert [detail] = assistant["reasoning_details"]
    assert detail["signature"] == "signed-reasoning"

    assert detail["provider_data"] == %{
             "$kodo_type" => "map",
             "entries" => [["id", "reasoning-1"], ["type", "reasoning.text"]]
           }

    assert [%{reasoning_details: [restored]}] =
             Adapter.build_context([
               %{"role" => "assistant", "provider_state" => assistant}
             ]).messages

    assert restored.provider_data == %{"id" => "reasoning-1", "type" => "reasoning.text"}
    refute inspect(assistant) =~ "private-provider-detail"
    refute inspect(assistant) =~ "unreviewed metadata"
  end

  test "drops unreviewed content metadata and rejects malformed reasoning fields" do
    private_detail = "private-provider-detail"

    responses = [
      %{
        "id" => "chat_image_metadata",
        "model" => "anthropic/claude-sonnet-4",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "image_url",
                  "image_url" => %{
                    "url" => "https://example.invalid/image.png",
                    "detail" => "high",
                    "debug" => %{"request_dump" => private_detail}
                  }
                }
              ]
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      },
      %{
        "id" => "chat_bad_reasoning",
        "model" => "anthropic/claude-sonnet-4",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "answer",
              "reasoning_details" => [
                %{
                  "type" => "reasoning.text",
                  "text" => "Checking the result.",
                  "format" => %{"request_dump" => private_detail},
                  "index" => 0
                }
              ]
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }
    ]

    server = start_provider_server(Enum.map(responses, &%{status: 200, body: &1}))
    previous = Application.get_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :openrouter, previous),
        else: Application.delete_env(:req_llm, :openrouter)
    end)

    credential = %{@credential | provider: "openrouter", billing_path: :aggregator}
    model = ReqLLM.model!("openrouter:anthropic/claude-sonnet-4")

    assert {:ok, %{assistant: assistant}} =
             Adapter.generate(
               model,
               [%{"role" => "user", "content" => "show image"}],
               [],
               credential,
               timeout: 5_000,
               reasoning: "none"
             )

    assert [%{"metadata" => %{"$kodo_type" => "map", "entries" => []}}] =
             assistant["content"]

    refute inspect(assistant) =~ private_detail

    assert {:error, %Kodo.LLM.ProviderError{kind: :request_failed} = error} =
             Adapter.generate(model, [%{"role" => "user", "content" => "answer"}], [], credential,
               timeout: 5_000,
               reasoning: "none"
             )

    refute inspect(error) =~ private_detail
  end

  test "rejects malformed promoted message metadata" do
    private_detail = "private-provider-detail"

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => %{"request_dump" => private_detail},
            "object" => "response",
            "model" => "gpt-4o-mini",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => "answer", "annotations" => []}
                ]
              }
            ],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        }
      ])

    options =
      []
      |> Adapter.request_options(@credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:error, error} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai:gpt-4o-mini"),
               [%{"role" => "user", "content" => "answer"}],
               options
             )

    refute inspect(error) =~ private_detail
  end

  test "drops unreviewed OpenAI builtin payloads" do
    private_detail = "private-provider-detail"

    server =
      start_provider_server([
        %{
          status: 200,
          body: %{
            "id" => "resp_builtin",
            "object" => "response",
            "model" => "gpt-4o-mini",
            "output" => [
              %{
                "type" => "web_search_call",
                "id" => "search-1",
                "status" => "completed",
                "action" => %{"type" => "search", "query" => "kodo"},
                "debug" => %{"request_dump" => private_detail}
              },
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => "answer", "annotations" => []}
                ]
              }
            ],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        }
      ])

    options =
      []
      |> Adapter.request_options(@credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:ok, response} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai:gpt-4o-mini"),
               [%{"role" => "user", "content" => "search"}],
               options
             )

    assert [%{id: "search-1"} = call] = ReqLLM.Response.tool_calls(response)
    assert ReqLLM.ToolCall.builtin?(call)
    assert ReqLLM.ToolCall.args_map(call) == %{}
    refute inspect(response.message) =~ private_detail
  end

  test "rejects credentials reconstructed from Codex SSE output" do
    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    completion =
      "event: response.completed\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_test",
            "model" => "gpt-5.4",
            "status" => "completed",
            "output" => [],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        }) <> "\n\n"

    split_body =
      "event: response.output_text.delta\ndata: " <>
        Jason.encode!(%{
          "type" => "response.output_text.delta",
          "delta" => "request-local-"
        }) <>
        "\n\n" <>
        "event: response.output_text.delta\ndata: " <>
        Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "access"}) <>
        "\n\n" <> completion

    split_deltas =
      split_body
      |> ReqLLM.Streaming.SSE.parse_sse_binary()
      |> Enum.filter(&(&1.event == "response.output_text.delta"))

    assert Enum.all?(split_deltas, &is_map(&1.data))
    assert Enum.map_join(split_deltas, & &1.data["delta"]) == credential.token

    bodies = [
      "event: response.output_text.delta\n" <>
        ~S(data: {"type":"response.output_text.delta","delta":"\u0072equest-local-access"}) <>
        "\n\n" <> completion,
      split_body
    ]

    for body <- bodies do
      server =
        start_provider_server([
          %{status: 200, body: body, content_type: "text/event-stream"}
        ])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      assert {:error, error} =
               ReqLLM.generate_text(
                 ReqLLM.model!("openai_codex:gpt-5.4"),
                 [%{"role" => "user", "content" => "private prompt"}],
                 options
               )

      refute inspect(error) =~ credential.token
    end

    safe_body =
      split_body
      |> String.replace("request-local-", "public-")
      |> String.replace(~s("delta":"access"), ~s("delta":"answer"))

    server =
      start_provider_server([
        %{status: 200, body: safe_body, content_type: "text/event-stream"}
      ])

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:ok, response} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai_codex:gpt-5.4"),
               [%{"role" => "user", "content" => "public prompt"}],
               options
             )

    assert ReqLLM.Response.text(response) == "public-answer"
  end

  test "rejects unsafe Codex tool streams before decoder diagnostics" do
    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    private_marker = "private-prompt-marker"

    added =
      Jason.encode!(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "name" => "read_file",
          "call_id" => private_marker
        }
      })

    delta =
      Jason.encode!(%{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => "{}"
      })

    builtin_done =
      Jason.encode!(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "web_search_call",
          "id" => "search-1",
          "action" => %{}
        }
      })

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_test",
          "model" => "gpt-5.4",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }
      })

    body =
      "event: response.output_item.added\ndata: #{added}\n\n" <>
        "event: response.function_call_arguments.delta\ndata: #{delta}\n\n" <>
        "event: response.output_item.done\ndata: #{builtin_done}\n\n" <>
        "event: response.completed\ndata: #{completed}\n\n"

    safe_added =
      Jason.encode!(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "function_call", "name" => "read_file", "call_id" => "call-1"}
      })

    safe_delta =
      Jason.encode!(%{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "delta" => ~s({"path":"mix.exs"})
      })

    safe_done =
      Jason.encode!(%{
        "type" => "response.function_call_arguments.done",
        "output_index" => 0,
        "arguments" => ~s({"path":"mix.exs"})
      })

    safe_body =
      "event: response.output_item.added\ndata: #{safe_added}\n\n" <>
        "event: response.function_call_arguments.delta\ndata: #{safe_delta}\n\n" <>
        "event: response.function_call_arguments.done\ndata: #{safe_done}\n\n" <>
        "event: response.completed\ndata: #{completed}\n\n"

    server =
      start_provider_server([
        %{status: 200, body: body, content_type: "text/event-stream"},
        %{status: 200, body: safe_body, content_type: "text/event-stream"}
      ])

    test_pid = self()
    handler_id = "safe-codex-tool-diagnostics-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:req_llm, :tool_call_args_lost],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:tool_diagnostic, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    log =
      capture_log(fn ->
        assert {:error, error} =
                 ReqLLM.generate_text(
                   ReqLLM.model!("openai_codex:gpt-5.4"),
                   [%{"role" => "user", "content" => "private prompt"}],
                   options
                 )

        refute inspect(error) =~ private_marker
      end)

    refute_receive {:tool_diagnostic, [:req_llm, :tool_call_args_lost], _, _}
    refute log =~ private_marker

    assert {:ok, response} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai_codex:gpt-5.4"),
               [%{"role" => "user", "content" => "use read_file"}],
               options
             )

    assert [%{id: "call-1"} = call] = ReqLLM.Response.tool_calls(response)
    assert ReqLLM.ToolCall.args_map(call) == %{"path" => "mix.exs"}
    refute_receive {:tool_diagnostic, [:req_llm, :tool_call_args_lost], _, _}
  end

  test "bounds malformed Codex event shapes before decoding" do
    private_marker = "private-prompt-marker"

    malformed =
      Jason.encode!(%{
        "type" => "response.function_call.delta",
        "delta" => private_marker
      })

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_test",
          "model" => "gpt-5.4",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }
      })

    body =
      "event: response.function_call.delta\ndata: #{malformed}\n\n" <>
        "event: response.completed\ndata: #{completed}\n\n"

    server =
      start_provider_server([
        %{status: 200, body: body, content_type: "text/event-stream"}
      ])

    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    log =
      capture_log(fn ->
        assert {:error, error} =
                 ReqLLM.generate_text(
                   ReqLLM.model!("openai_codex:gpt-5.4"),
                   [%{"role" => "user", "content" => "private prompt"}],
                   options
                 )

        refute inspect(error) =~ private_marker
      end)

    refute log =~ private_marker
  end

  test "drops unreviewed Codex builtin payloads" do
    private_detail = "private-provider-detail"

    added =
      Jason.encode!(%{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "web_search_call", "id" => "search-1"}
      })

    done =
      Jason.encode!(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "web_search_call",
          "id" => "search-1",
          "status" => "completed",
          "action" => %{"type" => "search", "query" => "kodo"},
          "debug" => %{"request_dump" => private_detail}
        }
      })

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_builtin",
          "model" => "gpt-5.4",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }
      })

    server =
      start_provider_server([
        %{
          status: 200,
          body:
            "event: response.output_item.added\ndata: #{added}\n\n" <>
              "event: response.output_item.done\ndata: #{done}\n\n" <>
              "event: response.completed\ndata: #{completed}\n\n",
          content_type: "text/event-stream"
        }
      ])

    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:ok, response} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai_codex:gpt-5.4"),
               [%{"role" => "user", "content" => "search"}],
               options
             )

    assert [%{id: "search-1"} = call] = ReqLLM.Response.tool_calls(response)
    assert ReqLLM.ToolCall.builtin?(call)
    assert ReqLLM.ToolCall.args_map(call) == %{}
    refute inspect(response.message) =~ private_detail
  end

  test "rejects Codex SSE that ends before a terminal event" do
    delta =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "Partial answer"
      })

    server =
      start_provider_server([
        %{
          status: 200,
          body: "event: response.output_text.delta\ndata: #{delta}\n\n",
          content_type: "text/event-stream"
        }
      ])

    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)

    assert {:error, error} =
             ReqLLM.generate_text(
               ReqLLM.model!("openai_codex:gpt-5.4"),
               [%{"role" => "user", "content" => "answer"}],
               options
             )

    refute inspect(error) =~ "Partial answer"
  end

  test "rejects malformed or conflicting Codex terminal envelopes" do
    delta =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => "Partial answer"
      })

    terminal = fn type, response ->
      "event: #{type}\ndata: " <>
        Jason.encode!(%{"type" => type, "response" => response}) <> "\n\n"
    end

    valid_response = %{
      "id" => "resp_valid",
      "model" => "gpt-5.4",
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    bodies = [
      terminal.("response.completed", %{}),
      terminal.("response.completed", %{"status" => "completed"}),
      terminal.("response.completed", valid_response) <>
        terminal.("response.incomplete", %{valid_response | "status" => "incomplete"})
    ]

    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    for terminal_body <- bodies do
      server =
        start_provider_server([
          %{
            status: 200,
            body: "event: response.output_text.delta\ndata: #{delta}\n\n" <> terminal_body,
            content_type: "text/event-stream"
          }
        ])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      assert {:error, _error} =
               ReqLLM.generate_text(
                 ReqLLM.model!("openai_codex:gpt-5.4"),
                 [%{"role" => "user", "content" => "answer"}],
                 options
               )
    end
  end

  test "accepts each supported Codex terminal envelope" do
    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    for {type, status} <- [
          {"response.completed", "completed"},
          {"response.done", "completed"},
          {"response.incomplete", "incomplete"}
        ] do
      delta =
        Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "answer"})

      terminal =
        Jason.encode!(%{
          "type" => type,
          "response" => %{
            "id" => "resp_#{status}",
            "model" => "gpt-5.4",
            "status" => status,
            "output" => [],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        })

      server =
        start_provider_server([
          %{
            status: 200,
            body:
              "event: response.output_text.delta\ndata: #{delta}\n\n" <>
                "event: #{type}\ndata: #{terminal}\n\n",
            content_type: "text/event-stream"
          }
        ])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      assert {:ok, response} =
               ReqLLM.generate_text(
                 ReqLLM.model!("openai_codex:gpt-5.4"),
                 [%{"role" => "user", "content" => "answer"}],
                 options
               )

      assert ReqLLM.Response.text(response) == "answer"
    end
  end

  test "accepts Codex native structured output" do
    delta =
      Jason.encode!(%{
        "type" => "response.output_text.delta",
        "delta" => ~s({"answer":"ok"})
      })

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_object",
          "model" => "gpt-5.4",
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }
      })

    server =
      start_provider_server([
        %{
          status: 200,
          body:
            "event: response.output_text.delta\ndata: #{delta}\n\n" <>
              "event: response.completed\ndata: #{completed}\n\n",
          content_type: "text/event-stream"
        }
      ])

    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    options =
      []
      |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
      |> Keyword.put(:base_url, server.base_url)
      |> Keyword.put(:output_validation, :strict)

    schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

    assert {:ok, response} =
             ReqLLM.generate_object(
               ReqLLM.model!("openai_codex:gpt-5.4"),
               [%{"role" => "user", "content" => "return an answer"}],
               schema,
               options
             )

    assert ReqLLM.Response.object(response) == %{"answer" => "ok"}
  end

  test "Kodo rejects empty Anthropic inference responses without crashing" do
    server =
      start_provider_server([
        %{status: 200, body: %{"data" => []}},
        %{
          status: 200,
          body: %{
            "id" => "msg_empty",
            "type" => "message",
            "content" => [],
            "model" => "claude-3-5-haiku-latest"
          }
        },
        %{
          status: 200,
          body: %{
            "id" => "msg_tool",
            "type" => "message",
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "call-1",
                "name" => "read_file",
                "input" => %{
                  "path" => "README.md",
                  "request-local-key" => "echo"
                }
              }
            ],
            "model" => "claude-3-5-haiku-latest"
          }
        }
      ])

    previous = Application.get_env(:req_llm, :anthropic)
    Application.put_env(:req_llm, :anthropic, base_url: server.base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req_llm, :anthropic, previous),
        else: Application.delete_env(:req_llm, :anthropic)
    end)

    credential = %{@credential | provider: "anthropic"}
    model = ReqLLM.model!("anthropic:claude-3-5-haiku-latest")

    for _response <- 1..3 do
      assert {:error, %Kodo.LLM.ProviderError{kind: :request_failed, retryable: false} = error} =
               Adapter.generate(
                 model,
                 [%{"role" => "user", "content" => "private prompt"}],
                 [],
                 credential,
                 timeout: 5_000,
                 reasoning: "none"
               )

      refute inspect(error) =~ credential.token
    end
  end

  test "classifies documented Anthropic spend caps as billing failures" do
    cases = [
      {400,
       %{
         "error" => %{
           "type" => "invalid_request_error",
           "message" => "You have reached your specified API usage limits; private reset detail"
         }
       }},
      {429,
       %{
         "error" => %{
           "type" => "rate_limit_error",
           "message" => "private reset detail",
           "details" => %{"error_code" => "enforced_spend_limit_reached"}
         }
       }}
    ]

    credential = %{@credential | provider: "anthropic"}
    model = ReqLLM.model!("anthropic:claude-3-5-haiku-latest")

    for {status, body} <- cases do
      server = start_provider_server([%{status: status, body: body}])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      assert {:error, error} =
               ReqLLM.generate_text(
                 model,
                 [%{"role" => "user", "content" => "private prompt"}],
                 options
               )

      assert %{kind: :billing_required, retryable: false} =
               Adapter.normalize_error(error, model, credential)

      refute inspect(error) =~ "private reset detail"
    end
  end

  test "invalid success bodies expose no prompt or credential telemetry" do
    secret = "malformed-response-secret"
    prompt = "private malformed-response prompt"
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

    responses = [
      %{status: 200, body: Jason.encode!("echo #{secret} #{prompt}")},
      %{status: 200, body: "echo #{secret} #{prompt}", content_type: "text/plain"},
      %{status: 200, body: %{"unexpected" => "echo #{secret} #{prompt}"}}
    ]

    for response <- responses do
      server = start_provider_server([response])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      log =
        capture_log(fn ->
          assert {:error, _error} =
                   ReqLLM.generate_text(
                     ReqLLM.model!("openai:gpt-4o-mini"),
                     [%{"role" => "user", "content" => prompt}],
                     options
                   )
        end)

      refute_receive {:provider_telemetry, [:finch, :request, :start], _metadata}
      assert_receive {:provider_telemetry, [:req_llm, :request, :exception], metadata}
      refute inspect(metadata) =~ secret
      refute inspect(metadata) =~ prompt
      refute log =~ secret
      refute log =~ prompt
    end
  end

  test "Codex failure events expose no provider or prompt details" do
    secret = "codex-response-secret"
    prompt = "private Codex prompt"

    credential = %{
      @credential
      | provider: "openai_codex",
        authentication_type: "oauth",
        billing_path: :subscription,
        token: "request-local-access",
        account_id: "request-local-account"
    }

    for event_type <- ["error", "response.failed"] do
      body =
        "event: #{event_type}\ndata: #{Jason.encode!(%{"type" => event_type, "message" => secret})}\n\n"

      server =
        start_provider_server([
          %{status: 200, body: body, content_type: "text/event-stream"}
        ])

      options =
        []
        |> Adapter.request_options(credential, timeout: 5_000, reasoning: "none")
        |> Keyword.put(:base_url, server.base_url)

      log =
        capture_log(fn ->
          assert {:error, error} =
                   ReqLLM.generate_text(
                     ReqLLM.model!("openai_codex:gpt-5.4"),
                     [%{"role" => "user", "content" => prompt}],
                     options
                   )

          refute inspect(error) =~ secret
          refute inspect(error) =~ prompt
        end)

      refute log =~ secret
      refute log =~ prompt
    end
  end

  test "connection refusal remains a retryable provider availability failure" do
    port = free_port()
    Application.put_env(:kodo, :safe_req_test_origins, [{"http", "127.0.0.1", port}])
    credential = %{@credential | token: "network-boundary-secret"}
    model = ReqLLM.model!("openai:gpt-4o-mini")

    options =
      []
      |> Adapter.request_options(credential, timeout: 1_000, reasoning: "none")
      |> Keyword.put(:base_url, "http://127.0.0.1:#{port}")

    assert {:error, error} =
             ReqLLM.generate_text(
               model,
               [%{"role" => "user", "content" => "private network prompt"}],
               options
             )

    assert %{kind: :provider_unavailable, retryable: true} =
             Adapter.normalize_error(error, model, credential)

    refute inspect(error) =~ "network-boundary-secret"
    refute inspect(error) =~ "private network prompt"
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
