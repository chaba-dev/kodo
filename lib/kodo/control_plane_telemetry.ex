defmodule Kodo.ControlPlaneTelemetry do
  @moduledoc "Bounded-cardinality telemetry metadata for control-plane database work."

  @query_event [:kodo, :control_plane, :query]

  def repo_options(operation) when is_atom(operation) do
    [telemetry_event: @query_event, telemetry_options: [operation: operation]]
  end
end
