defmodule Kodo.LLM.ReqLLM do
  @moduledoc "ReqLLM provider adapter that exposes only normalized Kodo values."

  @behaviour Kodo.LLM

  alias Kodo.Agent.ModelCapabilities
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Response
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  @reasoning_efforts %{
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh,
    "max" => :max
  }

  @impl true
  def validate_model(model, role_mapping, contract) do
    with {:ok, resolved} <- resolve_dispatchable_model(model),
         :ok <- validate_reasoning(role_mapping["reasoning"]) do
      ModelCapabilities.validate(resolved, role_mapping, contract)
    end
  end

  @impl true
  def generate(model, messages, tools, opts) do
    context = build_context(messages)
    request(model, context, tools, opts)
  end

  @impl true
  def generate_object(model, messages, schema, opts) do
    request_opts =
      [
        receive_timeout: Keyword.fetch!(opts, :timeout),
        total_timeout: Keyword.fetch!(opts, :timeout),
        output_validation: :strict
      ]
      |> put_reasoning_effort(opts[:reasoning])

    with {:ok, response} <-
           ReqLLM.generate_object(model, build_context(messages), schema, request_opts) do
      {:ok, %{object: Response.object(response), usage: Response.usage(response)}}
    end
  end

  @doc false
  def request_options(tools, opts) do
    [
      tools: build_tools(tools),
      receive_timeout: Keyword.fetch!(opts, :timeout),
      total_timeout: Keyword.fetch!(opts, :timeout)
    ]
    |> put_reasoning_effort(opts[:reasoning])
  end

  @doc false
  def build_context(messages) do
    messages
    |> Enum.map(&message/1)
    |> Context.new()
  end

  @doc false
  def build_tools(tools) do
    Enum.map(tools, fn tool ->
      Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.parameters,
        callback: &unused_callback/1,
        strict: true
      )
    end)
  end

  defp request(model, context, tools, opts) do
    request_opts = request_options(tools, opts)

    with {:ok, response} <- ReqLLM.generate_text(model, context, request_opts) do
      classified = Response.classify(response)
      tool_calls = Response.tool_calls(response)

      {:ok,
       %{
         type: classified.type,
         text: classified.text,
         tool_calls: Enum.map(tool_calls, &normalize_tool_call/1),
         usage: Response.usage(response),
         assistant: dump_assistant(response.message, classified.text, tool_calls)
       }}
    end
  end

  defp put_reasoning_effort(opts, reasoning) when reasoning in [nil, "none"], do: opts

  defp put_reasoning_effort(opts, reasoning) do
    Keyword.put(opts, :reasoning_effort, Map.fetch!(@reasoning_efforts, reasoning))
  end

  defp resolve_dispatchable_model(model) do
    with {:ok, resolved} <- ReqLLM.model(model),
         {:ok, _provider} <- ReqLLM.provider(resolved.provider) do
      {:ok, resolved}
    else
      {:error, reason} -> {:error, {:model_not_available, reason}}
    end
  end

  defp validate_reasoning(reasoning) when reasoning in [nil, "none"], do: :ok

  defp validate_reasoning(reasoning) do
    if Map.has_key?(@reasoning_efforts, reasoning),
      do: :ok,
      else: {:error, {:unsupported_reasoning, reasoning}}
  end

  defp message(%{"role" => "system", "content" => content}), do: Context.system(content)
  defp message(%{"role" => "user", "content" => content}), do: Context.user(content)

  defp message(%{"role" => "assistant", "provider_state" => %{"version" => 2} = state}) do
    %Message{
      role: :assistant,
      content: Enum.map(state["content"] || [], &load_content_part/1),
      name: state["name"],
      tool_call_id: state["tool_call_id"],
      metadata: load_term(state["metadata"] || %{}),
      reasoning_details: load_reasoning_details(state["reasoning_details"]),
      tool_calls: load_tool_calls(state["tool_calls"])
    }
  end

  defp message(%{"role" => "assistant", "provider_state" => state}) do
    assistant = Context.assistant(state["text"] || "")

    %{
      assistant
      | metadata: restore_legacy_message_metadata(state["metadata"] || %{}),
        reasoning_details: load_reasoning_details(state["reasoning_details"]),
        tool_calls: load_tool_calls(state["tool_calls"])
    }
  end

  defp message(%{"role" => "assistant", "content" => content, "tool_calls" => calls}) do
    Context.assistant(content,
      tool_calls: Enum.map(calls, &{&1["name"], &1["arguments"], id: &1["id"]})
    )
  end

  defp message(%{"role" => "assistant", "content" => content}), do: Context.assistant(content)

  defp message(%{"role" => "tool", "tool_call_id" => id, "name" => name, "content" => output}) do
    Context.tool_result(id, name, output)
  end

  defp normalize_tool_call(%ToolCall{} = call) do
    %{
      id: call.id,
      name: ToolCall.name(call),
      arguments: ToolCall.args_map(call)
    }
  end

  @doc false
  def dump_assistant(%Message{} = message, text, tool_calls) do
    %{
      "version" => 2,
      "text" => text,
      "content" => Enum.map(message.content, &dump_content_part/1),
      "name" => message.name,
      "tool_call_id" => message.tool_call_id,
      "metadata" => dump_term(message.metadata || %{}),
      "reasoning_details" => dump_reasoning_details(message.reasoning_details),
      "tool_calls" => Enum.map(tool_calls, &dump_tool_call/1)
    }
  end

  defp dump_reasoning_details(nil), do: nil
  defp dump_reasoning_details(details), do: Enum.map(details, &dump_reasoning_detail/1)

  defp dump_reasoning_detail(%ReasoningDetails{} = detail) do
    %{
      "text" => detail.text,
      "signature" => detail.signature,
      "encrypted" => detail.encrypted?,
      "provider" => detail.provider && Atom.to_string(detail.provider),
      "format" => detail.format,
      "index" => detail.index,
      "provider_data" => dump_term(detail.provider_data || %{})
    }
  end

  defp dump_tool_call(%ToolCall{} = call) do
    %{
      "id" => call.id,
      "type" => call.type,
      "function" => dump_term(call.function)
    }
  end

  defp dump_content_part(%ContentPart{} = part) do
    %{
      "type" => Atom.to_string(part.type),
      "text" => part.text,
      "url" => part.url,
      "data" => dump_binary(part.data),
      "file_id" => part.file_id,
      "media_type" => part.media_type,
      "filename" => part.filename,
      "metadata" => dump_term(part.metadata || %{})
    }
  end

  defp load_reasoning_details(nil), do: nil
  defp load_reasoning_details(details), do: Enum.map(details, &load_reasoning_detail/1)

  defp load_reasoning_detail(detail) do
    %ReasoningDetails{
      text: detail["text"],
      signature: detail["signature"],
      encrypted?: detail["encrypted"] || false,
      provider: existing_atom(detail["provider"]),
      format: detail["format"],
      index: detail["index"] || 0,
      provider_data: load_term(detail["provider_data"] || %{})
    }
  end

  defp load_tool_calls(nil), do: nil
  defp load_tool_calls(calls), do: Enum.map(calls, &load_tool_call/1)

  defp load_tool_call(call) do
    case call do
      %{"function" => function} ->
        %ToolCall{
          id: call["id"],
          type: call["type"] || "function",
          function: load_term(function)
        }

      legacy ->
        constructor = if legacy["builtin"], do: :new_builtin, else: :new

        tool_call =
          apply(ToolCall, constructor, [
            legacy["id"],
            legacy["name"],
            legacy["arguments_json"] || "{}"
          ])

        ToolCall.put_metadata(
          tool_call,
          restore_tool_metadata(legacy["metadata"] || %{})
        )
    end
  end

  defp load_content_part(part) do
    %ContentPart{
      type: existing_atom(part["type"]),
      text: part["text"],
      url: part["url"],
      data: load_binary(part["data"]),
      file_id: part["file_id"],
      media_type: part["media_type"],
      filename: part["filename"],
      metadata: load_term(part["metadata"] || %{})
    }
  end

  defp restore_tool_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn
      {"thought_signature", value}, restored ->
        Map.put(restored, :thought_signature, value)

      {"provider_native", value}, restored ->
        Map.put(restored, :provider_native, existing_atom(value) || value)

      {"provider_payload", value}, restored ->
        Map.put(restored, :provider_payload, value)

      {key, value}, restored ->
        Map.put(restored, key, value)
    end)
  end

  defp existing_atom(nil), do: nil

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp restore_legacy_message_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn
      {"response_id", value}, restored -> Map.put(restored, :response_id, value)
      {"phase", value}, restored -> Map.put(restored, :phase, value)
      {"phase_items", value}, restored -> Map.put(restored, :phase_items, value)
      {key, value}, restored -> Map.put(restored, key, value)
    end)
  end

  defp dump_term(value) when is_map(value) do
    %{
      "$kodo_type" => "map",
      "entries" => Enum.map(value, fn {key, item} -> [dump_term(key), dump_term(item)] end)
    }
  end

  defp dump_term(value) when is_tuple(value) do
    %{"$kodo_type" => "tuple", "items" => value |> Tuple.to_list() |> Enum.map(&dump_term/1)}
  end

  defp dump_term(value) when is_list(value), do: Enum.map(value, &dump_term/1)

  defp dump_term(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: %{"$kodo_type" => "atom", "value" => Atom.to_string(value)}

  defp dump_term(value) when is_binary(value), do: dump_binary(value)
  defp dump_term(value) when is_boolean(value) or is_number(value) or is_nil(value), do: value

  defp load_term(%{"$kodo_type" => "map", "entries" => entries}) do
    Map.new(entries, fn [key, value] -> {load_term(key), load_term(value)} end)
  end

  defp load_term(%{"$kodo_type" => "tuple", "items" => items}) do
    items |> Enum.map(&load_term/1) |> List.to_tuple()
  end

  defp load_term(%{"$kodo_type" => "atom", "value" => value}), do: existing_atom(value) || value
  defp load_term(%{"$kodo_type" => "binary", "base64" => value}), do: Base.decode64!(value)
  defp load_term(value) when is_list(value), do: Enum.map(value, &load_term/1)
  defp load_term(value), do: value

  defp dump_binary(nil), do: nil

  defp dump_binary(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      %{"$kodo_type" => "binary", "base64" => Base.encode64(value)}
    end
  end

  defp load_binary(value), do: load_term(value)

  defp unused_callback(_arguments), do: {:error, :execution_owned_by_kodo}
end
