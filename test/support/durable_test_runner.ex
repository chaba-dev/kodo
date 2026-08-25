defmodule Kodo.Test.DurableTestRunner do
  @moduledoc false

  def start_link({runner_id, owner}) do
    Task.start_link(fn ->
      :ok = Kodo.Cluster.Discovery.join_runner(runner_id)
      loop(runner_id, owner, MapSet.new(), %{})
    end)
  end

  def child_spec({runner_id, _owner} = init_arg) do
    %{
      id: {__MODULE__, runner_id},
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :temporary
    }
  end

  defp loop(runner_id, owner, executed, requests) do
    receive do
      {:tool_request, %{"request_id" => request_id} = request} ->
        if request["request"]["tool"] == "git_diff" do
          complete_review(runner_id, request)
          send(owner, {:review_completed, request_id})
          loop(runner_id, owner, MapSet.put(executed, request_id), requests)
        else
          if request_id in executed do
            send(owner, {:tool_request_replayed, request_id})
            loop(runner_id, owner, executed, Map.put(requests, request_id, request))
          else
            send(owner, {:tool_execution_started, request_id})

            loop(
              runner_id,
              owner,
              MapSet.put(executed, request_id),
              Map.put(requests, request_id, request)
            )
          end
        end

      {:complete, request_id} ->
        request = Map.fetch!(requests, request_id)

        Phoenix.PubSub.broadcast(
          Kodo.PubSub,
          "runner_responses:#{runner_id}",
          {:runner_tool_response, runner_id,
           %{
             "protocol_version" => 4,
             "request_id" => request["request_id"],
             "status" => "success",
             "response" => %{"result" => "files_changed", "paths" => []}
           }}
        )

        loop(runner_id, owner, executed, requests)

      {:authority_lease, _lease} ->
        loop(runner_id, owner, executed, requests)
    end
  end

  defp complete_review(runner_id, request) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner_id}",
      {:runner_tool_response, runner_id,
       %{
         "protocol_version" => 4,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => %{"result" => "output", "content" => "clean diff", "truncated" => false}
       }}
    )
  end
end
