defmodule Kodo.E2E.LiveSmokeOutcomeTest do
  use ExUnit.Case, async: true

  alias Kodo.Test.FullStackCase, as: Stack

  @first_event_sequence 1
  @second_event_sequence 2
  @successful_exit_code 0

  test "accepts a successful verified outcome regardless of the editing tool" do
    workspace = Path.join(System.tmp_dir!(), "kodo-live-outcome-#{Ecto.UUID.generate()}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "greeting.txt"), "hello\n")
    on_exit(fn -> File.rm_rf!(workspace) end)

    replay = %{
      "session" => %{"status" => "completed"},
      "events" => [
        %{
          "sequence" => @first_event_sequence,
          "type" => "tool_completed",
          "payload" => %{
            "name" => "poll_command",
            "output" => %{"status" => %{"exited" => %{"code" => @successful_exit_code}}}
          }
        },
        %{
          "sequence" => @second_event_sequence,
          "type" => "assistant_message_completed",
          "payload" => %{"content" => "Greeting corrected and verified."}
        }
      ]
    }

    assert Stack.assert_live_outcome!(replay, workspace)
  end
end
