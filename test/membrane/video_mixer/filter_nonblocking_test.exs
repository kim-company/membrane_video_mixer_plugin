defmodule Membrane.VideoMixer.FilterNonblockingTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.Buffer
  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator
  alias Membrane.VideoMixer.FrameSampler

  require Membrane.Pad

  test "sidebar starts late - mixer waits for all inputs before mixing" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)

    red_payload = FrameGenerator.solid_color_payload(format, :red)
    start_ref = make_ref()
    {sidebar_state, sidebar_generator} = waiting_generator(red_payload, start_ref)

    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :primary_sidebar}
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar, %DynamicSource{output: {sidebar_state, sidebar_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)
    sidebar_pid = Pipeline.get_child_pid!(pipeline, :sidebar)

    # Verify NO buffers are received while sidebar is waiting (mixer waits for all inputs)
    assert receive_buffer_nowait(pipeline) == nil

    # Start the sidebar
    send(sidebar_pid, {:start, start_ref})

    # Now buffers should arrive with both inputs mixed
    first = receive_buffer(pipeline, 4000)
    assert sample_color(first.payload, format, :right) == :red
    assert sample_color(first.payload, format, :left) == :green

    Pipeline.terminate(pipeline)
  end

  test "both inputs continuously generate mixed output" do
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
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Verify continuous mixing - consume several buffers
    Enum.each(1..5, fn _ ->
      buffer = receive_buffer(pipeline, 2000)
      assert sample_color(buffer.payload, format, :right) == :red
      assert sample_color(buffer.payload, format, :left) == :green
    end)

    Pipeline.terminate(pipeline)
  end

  test "both inputs start together and mix in sync" do
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
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Both inputs start immediately - mixer should output mixed frames
    buffer = receive_buffer(pipeline, 4000)
    assert sample_color(buffer.payload, format, :left) == :green
    assert sample_color(buffer.payload, format, :right) == :red

    # Verify continuous mixing
    Enum.each(1..3, fn _ ->
      buffer = receive_buffer(pipeline, 2000)
      assert sample_color(buffer.payload, format, :left) == :green
      assert sample_color(buffer.payload, format, :right) == :red
    end)

    Pipeline.terminate(pipeline)
  end

  defp waiting_generator(payload, start_ref, opts \\ []) do
    pts_start = Keyword.get(opts, :pts_start, 0)
    pts_step = Keyword.get(opts, :pts_step, 1)
    state = %{started?: false, pts: pts_start, ref: start_ref}

    generator = fn state, pad, _count ->
      state =
        if state.started? do
          state
        else
          receive do
            {:start, ref} when ref == state.ref -> %{state | started?: true}
          after
            0 -> state
          end
        end

      if state.started? do
        buffer = %Buffer{payload: payload, pts: state.pts}
        actions = [buffer: {pad, buffer}]
        {actions, %{state | pts: state.pts + pts_step}}
      else
        {[], state}
      end
    end

    {state, generator}
  end

  defp receive_buffer(pipeline, timeout) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        buffer

      {Membrane.Testing.Pipeline, ^pipeline, _other} ->
        receive_buffer(pipeline, timeout)
    after
      timeout ->
        flunk("no buffer received within timeout")
    end
  end

  defp receive_buffer_nowait(pipeline) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        buffer

      {Membrane.Testing.Pipeline, ^pipeline, _other} ->
        receive_buffer_nowait(pipeline)
    after
      500 ->
        nil
    end
  end

  defp sample_color(payload, %Membrane.RawVideo{height: height} = format, :left) do
    sample_width = 4
    sample_height = 4
    # Sample from well inside the left region to avoid rounding issues
    x = 16
    y = div(height - sample_height, 2)

    samples = FrameSampler.sample_area(payload, format, x, y, sample_width, sample_height)
    classify_color(samples)
  end

  defp sample_color(payload, %Membrane.RawVideo{height: height} = format, :right) do
    sample_width = 4
    sample_height = 4
    # Sample from well inside the right region to avoid rounding issues
    x = 48
    y = div(height - sample_height, 2)

    samples = FrameSampler.sample_area(payload, format, x, y, sample_width, sample_height)
    classify_color(samples)
  end

  defp classify_color(samples) do
    cond do
      FrameSampler.uniform_color?(samples, FrameSampler.color_to_yuv(:green)) -> :green
      FrameSampler.uniform_color?(samples, FrameSampler.color_to_yuv(:red)) -> :red
      FrameSampler.uniform_color?(samples, FrameSampler.color_to_yuv(:blue)) -> :blue
      FrameSampler.uniform_color?(samples, FrameSampler.color_to_yuv(:black)) -> :black
      true -> :unknown
    end
  end
end
