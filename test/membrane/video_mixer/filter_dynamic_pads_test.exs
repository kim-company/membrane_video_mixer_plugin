defmodule Membrane.VideoMixer.FilterDynamicPadsTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator
  alias Membrane.VideoMixer.FrameSampler

  require Membrane.Pad

  @receive_timeout 4000

  test "switches between single and primary_sidebar layouts as pads change" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

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
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    _buffer = await_matching_buffer(pipeline, format, &single_fit_green?/2)

    Pipeline.execute_actions(pipeline,
      spec: [
        child(:sidebar, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
        |> via_out(:output)
        |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :sidebar])
        |> get_child(:mixer)
      ]
    )

    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_red?/2)

    Pipeline.execute_actions(pipeline, remove_children: :sidebar)

    _buffer = await_matching_buffer(pipeline, format, &single_fit_green?/2)

    Pipeline.terminate(pipeline)
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

  defp single_fit_green?(payload, format) do
    samples = FrameSampler.sample_center_area(payload, format, 8, 8)
    FrameSampler.uniform_color?(samples, FrameSampler.color_to_yuv(:green))
  end

  defp primary_sidebar_green_red?(payload, %Membrane.RawVideo{height: height} = format) do
    sample_width = 4
    sample_height = 4
    # Sample from well inside the expected regions to avoid rounding issues
    left_x = 16
    right_x = 48
    y = div(height - sample_height, 2)

    left_samples = FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)
    right_samples = FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

    FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:green)) and
      FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:red))
  end
end
