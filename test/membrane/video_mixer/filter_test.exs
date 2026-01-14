defmodule Membrane.VideoMixer.FilterTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  alias Membrane.Pad
  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator
  alias Membrane.VideoMixer.FrameSampler
  alias Membrane.VideoMixer.Test.Support

  require Membrane.Pad

  test "single input preserves color in center area" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {generator_state, generator} = FrameGenerator.red_generator(format)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :single_fit}
    end

    spec = [
      child(:primary, %DynamicSource{output: {generator_state, generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    [%{buffer: %Membrane.Buffer{payload: payload}}] =
      Support.Pipeline.collect_buffers(spec, max_buffers: 1)

    samples = FrameSampler.sample_center_area(payload, format, 8, 8)
    expected = FrameSampler.color_to_yuv(:red)
    assert FrameSampler.uniform_color?(samples, expected)
  end

  test "two inputs split output into half red and half green" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {red_state, red_generator} = FrameGenerator.red_generator(format)
    {green_state, green_generator} = FrameGenerator.green_generator(format)

    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :hstack}
    end

    spec = [
      child(:primary, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :left])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:extra, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:input, 1), options: [role: :right])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    matched =
      await_matching_buffer(pipeline, 4000, fn %Membrane.Buffer{payload: payload} ->
        sample_width = 8
        sample_height = 8
        left_x = 8
        right_x = div(width, 2) + 8
        y = div(height - sample_height, 2)

        left_samples = FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)
        right_samples = FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

        FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:red)) and
          FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:green))
      end)

    assert matched != nil

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  test "vstack splits output into top red and bottom green" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {red_state, red_generator} = FrameGenerator.red_generator(format)
    {green_state, green_generator} = FrameGenerator.green_generator(format)

    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :vstack}
    end

    spec = [
      child(:primary, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :top])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:extra, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:input, 1), options: [role: :bottom])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    matched =
      await_matching_buffer(pipeline, 4000, fn %Membrane.Buffer{payload: payload} ->
        sample_width = 8
        sample_height = 8
        top_y = 8
        bottom_y = div(height, 2) + 8
        x = div(width - sample_width, 2)

        top_samples = FrameSampler.sample_area(payload, format, x, top_y, sample_width, sample_height)
        bottom_samples = FrameSampler.sample_area(payload, format, x, bottom_y, sample_width, sample_height)

        FrameSampler.uniform_color?(top_samples, FrameSampler.color_to_yuv(:red)) and
          FrameSampler.uniform_color?(bottom_samples, FrameSampler.color_to_yuv(:green))
      end)

    assert matched != nil

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  test "xstack splits output into four colored quadrants" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {red_state, red_generator} = FrameGenerator.red_generator(format)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {blue_state, blue_generator} = FrameGenerator.blue_generator(format)
    {yellow_state, yellow_generator} = FrameGenerator.solid_color_generator(format, :yellow)

    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :xstack}
    end

    spec = [
      child(:primary, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :top_left])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:top_right, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:input, :top_right), options: [role: :top_right])
      |> get_child(:mixer),
      child(:bottom_left, %DynamicSource{output: {blue_state, blue_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:input, :bottom_left), options: [role: :bottom_left])
      |> get_child(:mixer),
      child(:bottom_right, %DynamicSource{output: {yellow_state, yellow_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:input, :bottom_right), options: [role: :bottom_right])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    matched =
      await_matching_buffer(pipeline, 4000, fn %Membrane.Buffer{payload: payload} ->
        sample_width = 8
        sample_height = 8
        left_x = 8
        right_x = div(width, 2) + 8
        top_y = 8
        bottom_y = div(height, 2) + 8

        top_left = FrameSampler.sample_area(payload, format, left_x, top_y, sample_width, sample_height)
        top_right = FrameSampler.sample_area(payload, format, right_x, top_y, sample_width, sample_height)
        bottom_left = FrameSampler.sample_area(payload, format, left_x, bottom_y, sample_width, sample_height)
        bottom_right = FrameSampler.sample_area(payload, format, right_x, bottom_y, sample_width, sample_height)

        FrameSampler.uniform_color?(top_left, FrameSampler.color_to_yuv(:red)) and
          FrameSampler.uniform_color?(top_right, FrameSampler.color_to_yuv(:green)) and
          FrameSampler.uniform_color?(bottom_left, FrameSampler.color_to_yuv(:blue)) and
          FrameSampler.uniform_color?(bottom_right, FrameSampler.color_to_yuv(:yellow))
      end)

    assert matched != nil

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  test "primary_sidebar splits output into primary green and sidebar red" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :primary_sidebar}
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:input, :sidebar), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    matched =
      await_matching_buffer(pipeline, 4000, fn %Membrane.Buffer{payload: payload} ->
        sample_width = 8
        sample_height = 8
        left_width = div(width * 2, 3)
        right_width = width - left_width
        left_x = div(left_width - sample_width, 2)
        right_x = left_width + div(right_width - sample_width, 2)
        y = div(height - sample_height, 2)

        left_samples = FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)
        right_samples = FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

        FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:green)) and
          FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:red))
      end)

    assert matched != nil

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  defp await_matching_buffer(pipeline, timeout, predicate) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_matching_buffer(pipeline, predicate, deadline)
  end

  defp do_await_matching_buffer(pipeline, predicate, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      nil
    else
      receive do
        {Membrane.Testing.Pipeline, ^pipeline,
         {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
          if predicate.(buffer), do: buffer, else: do_await_matching_buffer(pipeline, predicate, deadline)

        {Membrane.Testing.Pipeline, ^pipeline, _other} ->
          do_await_matching_buffer(pipeline, predicate, deadline)
      after
        remaining ->
          nil
      end
    end
  end
end
