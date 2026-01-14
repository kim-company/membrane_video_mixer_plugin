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

    [%{buffer: %Membrane.Buffer{payload: payload}}] =
      Support.Pipeline.collect_buffers(spec, max_buffers: 1)

    sample_width = 8
    sample_height = 8
    left_x = 8
    right_x = div(width, 2) + 8
    y = div(height - sample_height, 2)

    left_samples = FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)
    right_samples = FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

    assert FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:red))
    assert FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:green))
  end
end
