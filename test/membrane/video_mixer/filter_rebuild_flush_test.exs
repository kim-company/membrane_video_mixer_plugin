defmodule Membrane.VideoMixer.FilterRebuildFlushTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator
  alias Membrane.VideoMixer.FrameSampler

  require Membrane.Pad

  @receive_timeout 4000

  test "rebuild_filter_graph flushes stale non-primary frames" do
    # Setup: primary (green) + sidebar source (red), but layout starts as single_fit.
    # The sidebar's FrameQueue accumulates frames while not being rendered.
    # After rebuild_filter_graph switches to primary_sidebar, the first mixed frame
    # must use the sidebar's LATEST frame (not stale ones from the queue backlog).
    #
    # We prove this by:
    # 1. Running single_fit with both sources connected (sidebar queues up)
    # 2. Removing the red sidebar source
    # 3. Adding a blue sidebar source on the same role
    # 4. Sending rebuild_filter_graph to switch to primary_sidebar
    # 5. Asserting the sidebar shows blue (current), never red (stale)

    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)
    {blue_state, blue_generator} = FrameGenerator.blue_generator(format)

    # Layout builder: single_fit unless builder_state says :split
    layout_builder = fn _output_spec, specs_by_role, builder_state ->
      if builder_state == :split and Map.has_key?(specs_by_role, :sidebar) do
        {:layout, :primary_sidebar}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{
        layout_builder: layout_builder,
        builder_state: :single
      }),
      # Red sidebar source — its frames will queue up while layout is single_fit
      child(:sidebar_red, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar_red), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Wait for single_fit green output — this means both sources are flowing
    # and the sidebar queue is accumulating frames
    _buffer = await_matching_buffer(pipeline, format, &single_fit_green?/2)

    # Let more frames accumulate in the sidebar queue
    Process.sleep(200)

    # Remove the red source and add a blue one on a new role
    Pipeline.execute_actions(pipeline, remove_children: :sidebar_red)

    Pipeline.execute_actions(pipeline,
      spec: [
        child(:sidebar_blue, %DynamicSource{output: {blue_state, blue_generator}, stream_format: format})
        |> via_out(:output)
        |> via_in(Membrane.Pad.ref(:input, :sidebar_blue), options: [role: :sidebar])
        |> get_child(:mixer)
      ]
    )

    # Now switch to split layout — this triggers rebuild_filter_graph
    # which should flush stale frames from the sidebar queue
    Pipeline.execute_actions(pipeline,
      notify_child: {:mixer, {:rebuild_filter_graph, :split}}
    )

    # The first primary_sidebar frame must show blue sidebar (not red)
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_blue?/2)

    # Verify we never see red in the sidebar after the switch
    assert_no_red_sidebar(pipeline, format, 500)

    Pipeline.terminate(pipeline)
  end

  test "rebuild_filter_graph without builder_state also flushes queues" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {blue_state, blue_generator} = FrameGenerator.blue_generator(format)

    # Always use primary_sidebar when sidebar exists
    layout_builder = fn _output_spec, specs_by_role, _builder_state ->
      if Map.has_key?(specs_by_role, :sidebar) do
        {:layout, :primary_sidebar}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar, %DynamicSource{output: {blue_state, blue_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Wait for primary_sidebar to be active
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_blue?/2)

    # Send bare rebuild (no builder_state) — should also flush queues
    Pipeline.execute_actions(pipeline,
      notify_child: {:mixer, :rebuild_filter_graph}
    )

    # Layout should recover with blue sidebar (no stale frames causing issues)
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_blue?/2)

    Pipeline.terminate(pipeline)
  end

  # Helpers

  defp single_fit_green?(payload, format) do
    samples = FrameSampler.sample_center_area(payload, format, 8, 8)
    FrameSampler.uniform_color?(samples, FrameSampler.color_to_yuv(:green))
  end

  defp primary_sidebar_green_blue?(payload, %Membrane.RawVideo{height: height} = format) do
    sample_width = 4
    sample_height = 4
    left_x = 16
    right_x = 48
    y = div(height - sample_height, 2)

    left_samples =
      FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)

    right_samples =
      FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

    FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:green)) and
      FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:blue))
  end

  defp primary_sidebar_has_red_sidebar?(payload, %Membrane.RawVideo{height: height} = format) do
    sample_width = 4
    sample_height = 4
    right_x = 48
    y = div(height - sample_height, 2)

    right_samples =
      FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

    FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:red))
  end

  defp assert_no_red_sidebar(pipeline, format, duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    do_assert_no_red_sidebar(pipeline, format, deadline)
  end

  defp do_assert_no_red_sidebar(pipeline, format, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :ok
    else
      receive do
        {Membrane.Testing.Pipeline, ^pipeline,
         {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
          refute primary_sidebar_has_red_sidebar?(buffer.payload, format),
                 "detected stale red sidebar frame after rebuild"

          do_assert_no_red_sidebar(pipeline, format, deadline)

        {Membrane.Testing.Pipeline, ^pipeline, _other} ->
          do_assert_no_red_sidebar(pipeline, format, deadline)
      after
        remaining -> :ok
      end
    end
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
