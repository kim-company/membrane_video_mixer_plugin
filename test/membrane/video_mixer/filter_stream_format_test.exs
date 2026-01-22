defmodule Membrane.VideoMixer.FilterStreamFormatTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator

  require Membrane.Pad

  test "stream_format is emitted with first mixed buffer, not on handle_stream_format" do
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

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Assert stream_format is received
    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{width: ^width, height: ^height})

    # Assert buffer is received after
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})

    Pipeline.terminate(pipeline)
  end

  test "mid-stream spec change emits new stream_format" do
    width = 64
    height = 48
    format1 = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    format2 = FrameGenerator.stream_format(width * 2, height * 2, framerate: {30, 1}, pixel_format: :I420)

    # Create a generator that changes resolution mid-stream
    {generator_state, generator} = resolution_changing_generator(format1, format2, 3)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :single_fit}
    end

    spec = [
      child(:primary, %DynamicSource{output: {generator_state, generator}, stream_format: format1})
      |> via_out(:output)
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Assert initial stream_format is received
    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{width: ^width, height: ^height})

    # Skip initial buffers (3 buffers before resolution change)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})

    # Assert new stream_format with changed resolution
    new_width = width * 2
    new_height = height * 2
    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{width: ^new_width, height: ^new_height})

    # Assert buffer after resolution change
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})

    Pipeline.terminate(pipeline)
  end

  test "output PTS comes from primary input" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)

    # Create generators with specific PTS values
    primary_pts_start = 1000
    {primary_state, primary_generator} = pts_generator(format, primary_pts_start, 100)
    {secondary_state, secondary_generator} = pts_generator(format, 5000, 100)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :hstack}
    end

    spec = [
      child(:primary, %DynamicSource{output: {primary_state, primary_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :left])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:secondary, %DynamicSource{output: {secondary_state, secondary_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, 1), options: [role: :right])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Skip stream format
    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

    # Check first 3 buffers have correct PTS from primary
    Enum.each(0..2, fn i ->
      expected_pts = primary_pts_start + (i * 100)
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: ^expected_pts})
    end)

    Pipeline.terminate(pipeline)
  end

  # Helper: creates a generator that changes resolution after N buffers
  defp resolution_changing_generator(format1, format2, change_after_count) do
    payload1 = FrameGenerator.solid_color_payload(format1, :red)
    payload2 = FrameGenerator.solid_color_payload(format2, :blue)

    state = %{
      count: 0,
      change_after: change_after_count,
      pts: 0,
      format1: format1,
      format2: format2,
      payload1: payload1,
      payload2: payload2
    }

    generator = fn state, pad, _count ->
      if state.count == state.change_after do
        # Emit new stream format
        actions = [
          stream_format: {pad, state.format2},
          buffer: {pad, %Buffer{payload: state.payload2, pts: state.pts}}
        ]
        {actions, %{state | count: state.count + 1, pts: state.pts + 1}}
      else
        # Emit regular buffer
        payload = if state.count < state.change_after, do: state.payload1, else: state.payload2
        buffer = %Buffer{payload: payload, pts: state.pts}
        actions = [buffer: {pad, buffer}]
        {actions, %{state | count: state.count + 1, pts: state.pts + 1}}
      end
    end

    {state, generator}
  end

  # Helper: creates a generator with specific PTS values
  defp pts_generator(format, pts_start, pts_step) do
    payload = FrameGenerator.solid_color_payload(format, :red)
    state = %{pts: pts_start, pts_step: pts_step}

    generator = fn state, pad, _count ->
      buffer = %Buffer{payload: payload, pts: state.pts}
      actions = [buffer: {pad, buffer}]
      {actions, %{state | pts: state.pts + state.pts_step}}
    end

    {state, generator}
  end
end
