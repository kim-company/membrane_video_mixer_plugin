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

  test "sidebar starts late and uses black until first frame" do
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

    first = receive_buffer(pipeline)
    assert sample_color(first.payload, format, :right) == :black
    assert sample_color(first.payload, format, :left) == :green

    send(sidebar_pid, {:start, start_ref})

    second = await_buffer_with_color(pipeline, format, :right, :red)
    assert sample_color(second.payload, format, :left) == :green

    Pipeline.terminate(pipeline)
  end

  test "sidebar pauses and holds last frame until it resumes" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)

    red_payload = FrameGenerator.solid_color_payload(format, :red)
    blue_payload = FrameGenerator.solid_color_payload(format, :blue)

    {sidebar_state, sidebar_generator} =
      phased_generator([
        {:emit, red_payload, 1},
        {:pause, 5},
        {:emit, blue_payload, 1}
      ])

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
    _red = await_buffer_with_color(pipeline, format, :right, :red)
    right_colors = collect_colors_until(pipeline, format, :right, :blue, 20)

    assert Enum.all?(Enum.drop(right_colors, -1), &(&1 == :red))
    assert List.last(right_colors) == :blue

    Pipeline.terminate(pipeline)
  end

  defp phased_generator(phases, opts \\ []) do
    pts_start = Keyword.get(opts, :pts_start, 0)
    pts_step = Keyword.get(opts, :pts_step, 1)

    state = %{phases: phases, pts: pts_start}

    generator = fn state, pad, _count ->
      case next_phase(state.phases) do
        {:emit, payload, _remaining, rest} ->
          buffer = %Buffer{payload: payload, pts: state.pts}
          actions = [buffer: {pad, buffer}]
          next_state = %{state | phases: rest, pts: state.pts + pts_step}
          {actions, next_state}

        {:pause, _remaining, rest} ->
          next_state = %{state | phases: rest}
          {[], next_state}
      end
    end

    {state, generator}
  end

  defp next_phase([{:emit, payload, count} | rest]) when count > 1 do
    {:emit, payload, count, [{:emit, payload, count - 1} | rest]}
  end

  defp next_phase([{:emit, payload, 1} | rest]) do
    {:emit, payload, 1, rest}
  end

  defp next_phase([{:pause, count} | rest]) when count > 1 do
    {:pause, count, [{:pause, count - 1} | rest]}
  end

  defp next_phase([{:pause, 1} | rest]) do
    {:pause, 1, rest}
  end

  defp next_phase([]) do
    {:pause, 1, []}
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

  defp receive_buffer(pipeline, timeout \\ 2000) do
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

  defp await_buffer_with_color(pipeline, format, side, expected, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_buffer_with_color(pipeline, format, side, expected, deadline)
  end

  defp collect_colors_until(pipeline, format, side, target, max_buffers) do
    Enum.reduce_while(1..max_buffers, [], fn _step, acc ->
      buffer = receive_buffer(pipeline, 2000)
      color = sample_color(buffer.payload, format, side)
      acc = acc ++ [color]

      if color == target do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp do_await_buffer_with_color(pipeline, format, side, expected, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("no buffer with #{inspect(expected)} on #{inspect(side)} within timeout")
    end

    buffer = receive_buffer(pipeline, remaining)

    if sample_color(buffer.payload, format, side) == expected do
      buffer
    else
      do_await_buffer_with_color(pipeline, format, side, expected, deadline)
    end
  end

  defp sample_color(payload, %Membrane.RawVideo{width: width, height: height} = format, :left) do
    sample_width = 8
    sample_height = 8
    left_width = div(width * 2, 3)
    x = div(left_width - sample_width, 2)
    y = div(height - sample_height, 2)

    samples = FrameSampler.sample_area(payload, format, x, y, sample_width, sample_height)
    classify_color(samples)
  end

  defp sample_color(payload, %Membrane.RawVideo{width: width, height: height} = format, :right) do
    sample_width = 8
    sample_height = 8
    left_width = div(width * 2, 3)
    right_width = width - left_width
    x = left_width + div(right_width - sample_width, 2)
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
