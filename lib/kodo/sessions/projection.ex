defmodule Kodo.Sessions.Projection do
  @moduledoc "Reconstructs all agent-visible session state solely from persisted events."

  @before_first_event_sequence 0

  defstruct [
    :id,
    :title,
    :runner_id,
    :model,
    :model_mapping,
    approval_policy: "standard",
    status: "idle",
    pending_approval_id: nil,
    last_sequence: @before_first_event_sequence,
    messages: [],
    tool_calls: %{}
  ]

  def from_events(events) do
    projection =
      Enum.reduce(events, %__MODULE__{}, fn event, projection ->
        projection =
          if event.type in ["user_message", "assistant_message_completed"],
            do: %{projection | messages: []},
            else: projection

        apply_event(event, projection)
      end)

    messages =
      for event <- events,
          event.type in ["user_message", "assistant_message_completed"],
          do: %{"role" => event.payload["role"], "content" => event.payload["content"]}

    %{projection | messages: messages}
  end

  def from_session(session, last_sequence, tool_calls \\ %{}) do
    %__MODULE__{
      id: session.id,
      title: session.title,
      runner_id: session.runner_id,
      model: session.model,
      model_mapping: nil,
      approval_policy: session.approval_policy,
      status: session.status,
      last_sequence: last_sequence,
      tool_calls: tool_calls
    }
  end

  def apply_event(event, projection) do
    projection
    |> Map.put(:id, event.session_id)
    |> Map.put(:last_sequence, event.sequence)
    |> reduce(event.type, event.payload)
  end

  defp reduce(projection, "session_created", payload) do
    %{
      projection
      | title: payload["title"],
        runner_id: payload["runner_id"],
        model: payload["model"],
        model_mapping: payload["model_mapping"],
        approval_policy: payload["approval_policy"] || "standard",
        status: payload["status"]
    }
  end

  defp reduce(projection, "session_status_changed", payload) do
    %{projection | status: payload["status"]}
  end

  defp reduce(projection, "session_cancelled", _payload) do
    %{projection | status: "cancelled"}
  end

  defp reduce(projection, "approval_requested", payload) do
    %{projection | pending_approval_id: payload["approval_id"]}
  end

  defp reduce(projection, "approval_resolved", payload) do
    if projection.pending_approval_id == payload["approval_id"] do
      %{projection | pending_approval_id: nil}
    else
      projection
    end
  end

  defp reduce(projection, type, payload)
       when type in ["user_message", "assistant_message_completed"] do
    message = %{"role" => payload["role"], "content" => payload["content"]}
    %{projection | messages: projection.messages ++ [message]}
  end

  defp reduce(projection, type, payload)
       when type in ["tool_requested", "tool_started", "tool_completed", "tool_failed"] do
    call_id = payload["tool_call_id"]

    call =
      projection.tool_calls
      |> Map.get(call_id, %{})
      |> Map.merge(payload)
      |> Map.put("state", type)

    %{projection | tool_calls: Map.put(projection.tool_calls, call_id, call)}
  end

  defp reduce(projection, _type, _payload), do: projection
end
