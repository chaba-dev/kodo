defmodule Kodo.Test.OpenAICodexContractProbeTest do
  use ExUnit.Case, async: true

  alias Kodo.Test.OpenAICodexContractProbe

  test "extracts model identity only from a terminal provider event" do
    body = """
    event: response.created
    data: {"type":"response.created","response":{"model":"untrusted-early-value"}}

    event: response.completed
    data: {"type":"response.completed","response":{"model":"gpt-5.4","output":[]}}

    data: [DONE]

    """

    assert OpenAICodexContractProbe.provider_model_from_sse(body) == "gpt-5.4"
  end

  test "returns nil when the terminal event omits model identity" do
    body = """
    event: response.completed
    data: {"type":"response.completed","response":{"output":[]}}

    data: [DONE]

    """

    assert OpenAICodexContractProbe.provider_model_from_sse(body) == nil
  end
end
