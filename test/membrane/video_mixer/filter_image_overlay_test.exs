defmodule Membrane.VideoMixer.FilterImageOverlayTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator
  alias Membrane.VideoMixer.FrameSampler

  require Membrane.Pad

  @receive_timeout 4000

  # Composite an RGBA overlay onto an I420 primary in one libavfilter pass.
  # The overlay filter's `format` option takes ffmpeg's enum alias (`yuv420`),
  # not the pix_fmt string (`yuv420p`) — the standalone `format` filter is
  # the other way round.
  @overlay_graph {
    "[1:v]format=yuva420p[ovl];[0:v][ovl]overlay=x=0:y=0:format=yuv420[out]",
    [0, 1]
  }

  test "an RGBA overlay pad covers the primary; removing it restores the primary" do
    width = 64
    height = 48
    i420 = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    rgba = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :RGBA)

    {green_state, green_gen} = FrameGenerator.green_generator(i420)
    {red_state, red_gen} = FrameGenerator.red_generator(rgba)

    layout_builder = fn _output_spec, specs_by_role, _state ->
      if Map.has_key?(specs_by_role, :overlay) do
        {:raw, @overlay_graph}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_gen}, stream_format: i420})
      |> via_out(:output)
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Primary only → solid green base (Y ≈ 150 in the unconverted bytes).
    _ = await_matching_buffer(pipeline, i420, &center_y_in?(&1, &2, 140..160))

    # Attach the overlay pad at runtime.
    Pipeline.execute_actions(pipeline,
      spec: [
        child(:overlay, %DynamicSource{output: {red_state, red_gen}, stream_format: rgba})
        |> via_out(:output)
        |> via_in(Membrane.Pad.ref(:input, :overlay), options: [role: :overlay])
        |> get_child(:mixer)
      ]
    )

    # Opaque red overlay → centre Y drops to ~81 (BT.601 limited red after the
    # RGBA → yuva420p → yuv420 conversion inside the filter).
    _ = await_matching_buffer(pipeline, i420, &center_y_in?(&1, &2, 60..100))

    # Drop the overlay → primary uncovered, centre Y back near green.
    Pipeline.execute_actions(pipeline, remove_children: :overlay)

    _ = await_matching_buffer(pipeline, i420, &center_y_in?(&1, &2, 140..160))

    Pipeline.terminate(pipeline)
  end

  defp center_y_in?(payload, format, range) do
    samples = FrameSampler.sample_center_area(payload, format, 8, 8)
    Enum.all?(samples, fn {y, _u, _v} -> y in range end)
  end

  defp await_matching_buffer(pipeline, format, predicate, timeout \\ @receive_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_matching_buffer(pipeline, format, predicate, deadline)
  end

  defp do_await_matching_buffer(pipeline, format, predicate, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("no matching buffer received within timeout")
    end

    receive do
      {Membrane.Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        if predicate.(buffer.payload, format) do
          buffer
        else
          do_await_matching_buffer(pipeline, format, predicate, deadline)
        end

      {Membrane.Testing.Pipeline, ^pipeline, _other} ->
        do_await_matching_buffer(pipeline, format, predicate, deadline)
    after
      remaining ->
        flunk("no matching buffer received within timeout")
    end
  end
end
