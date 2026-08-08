defmodule Kodo.CI.LiveSmokeWorkflowTest do
  use ExUnit.Case, async: true

  @workflow_path Path.expand("../../.github/workflows/live-smoke-test.yml", __DIR__)

  setup_all do
    %{workflow: File.read!(@workflow_path)}
  end

  test "reports a terminal result from a job outside the protected environment", %{
    workflow: workflow
  } do
    smoke_job = yaml_block!(workflow, "  smoke:")
    report_job = yaml_block!(workflow, "  report:")

    refute smoke_job =~ "Report result"
    assert report_job =~ "needs: [resolve, smoke]"
    assert report_job =~ "always() && needs.resolve.result == 'success'"
    assert report_job =~ "needs.smoke.result"
  end

  test "does not grant issue write permission to untrusted PR code", %{workflow: workflow} do
    global_permissions = yaml_block!(workflow, "permissions:")
    resolve_job = yaml_block!(workflow, "  resolve:")
    smoke_job = yaml_block!(workflow, "  smoke:")
    report_job = yaml_block!(workflow, "  report:")

    refute global_permissions =~ "issues: write"
    assert resolve_job =~ "issues: write"
    refute smoke_job =~ "issues: write"
    assert report_job =~ "issues: write"
  end

  defp yaml_block!(yaml, heading) do
    lines = String.split(yaml, "\n")
    heading_indent = byte_size(heading) - byte_size(String.trim_leading(heading))

    case Enum.split_while(lines, &(&1 != heading)) do
      {_before, [_heading | rest]} ->
        rest
        |> Enum.take_while(&(blank?(&1) or indentation(&1) > heading_indent))
        |> Enum.join("\n")

      {_before, []} ->
        flunk("missing YAML block #{heading}")
    end
  end

  defp blank?(line), do: String.trim(line) == ""
  defp indentation(line), do: byte_size(line) - byte_size(String.trim_leading(line))
end
