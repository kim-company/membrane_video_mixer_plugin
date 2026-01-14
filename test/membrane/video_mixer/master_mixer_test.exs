defmodule Membrane.VideoMixer.MasterMixerTest do
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

    filter_builder = fn _output_spec, _inputs, _builder_state ->
      {"[0:v]null[out]", [0]}
    end

    spec = [
      child(:master, %DynamicSource{output: {generator_state, generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:master)
      |> child(:mixer, %Membrane.VideoMixer.MasterMixer{filter_graph_builder: filter_builder}),
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

    filter_builder = fn
      %VideoMixer.FrameSpec{width: w, height: h}, specs, _builder_state when length(specs) == 1 ->
        {"[0:v]scale=#{w}:#{h}:force_original_aspect_ratio=decrease,pad=#{w}:#{h}:-1:-1,setsar=1[out]",
         [0]}

      %VideoMixer.FrameSpec{width: w, height: h}, _specs, _builder_state ->
        half_width = div(w, 2)

        graph =
          "[0:v]scale=#{half_width}:#{h}:force_original_aspect_ratio=decrease," <>
            "pad=#{half_width}:#{h}:-1:-1,setsar=1[l];" <>
            "[1:v]scale=#{half_width}:#{h}:force_original_aspect_ratio=decrease," <>
            "pad=#{half_width}:#{h}:-1:-1,setsar=1[r];" <>
            "[l][r]hstack=inputs=2[out]"

        {graph, [0, 1]}
    end

    spec = [
      child(:master, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:master)
      |> child(:mixer, %Membrane.VideoMixer.MasterMixer{filter_graph_builder: filter_builder}),
      child(:extra, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Pad.ref(:extra, 1))
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
