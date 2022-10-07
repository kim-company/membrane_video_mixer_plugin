defmodule Membrane.VideoMixer.FrameQueueTest do
  use ExUnit.Case, async: true
  alias Membrane.VideoMixer.FrameQueue

  test "init" do
    assert {{nil, {[], []}}, []} == FrameQueue.new()
  end

  test "pipeline" do
    queue = FrameQueue.new()

    queue =
      queue
      |> FrameQueue.put_caps("caps_1")
      |> FrameQueue.put_frame("1")
      |> FrameQueue.put_frame("1")
      |> FrameQueue.put_caps("caps_2")
      |> FrameQueue.put_frame("2")
      |> FrameQueue.put_frame("2")
      |> FrameQueue.put_caps("caps_3")
      |> FrameQueue.put_frame("3")
      |> FrameQueue.put_frame("3")

    assert queue ==
             {{nil, {[], []}},
              [
                {"caps_3", {["3"], ["3"]}},
                {"caps_2", {["2"], ["2"]}},
                {"caps_1", {["1"], ["1"]}}
              ]}

    assert 6 == FrameQueue.frames_length(queue)
    assert {{:change, "1"}, queue} = FrameQueue.get_frame(queue)
    assert {{:ok, "1"}, queue} = FrameQueue.get_frame(queue)
    assert 4 == FrameQueue.frames_length(queue)
    assert {{:change, "2"}, queue} = FrameQueue.get_frame(queue)
    assert {{:ok, "2"}, queue} = FrameQueue.get_frame(queue)
    assert 2 == FrameQueue.frames_length(queue)
    assert {{:change, "3"}, queue} = FrameQueue.get_frame(queue)
    assert {{:ok, "3"}, queue} = FrameQueue.get_frame(queue)
    assert true == FrameQueue.empty?(queue)
  end
end
