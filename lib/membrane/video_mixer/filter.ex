defmodule Membrane.VideoMixer.Filter do
  @moduledoc """
  Provides a Membrane.Filter that produces a video output of the same size and
  pixel properties of its primary video input, mixed with other video sources
  according to the provided filtering.
  """

  use Membrane.Filter

  alias VideoMixer
  alias VideoMixer.Frame
  alias VideoMixer.FrameSpec
  alias VideoMixer.FrameQueue

  require Membrane.Logger

  @type layout_builder_t ::
          (output_spec :: FrameSpec.t(), inputs :: %{atom() => FrameSpec.t()}, builder_state :: any ->
             {:layout, VideoMixer.FilterGraph.layout()} | {:raw, VideoMixer.filter_graph_t()})

  def_options(
    layout_builder: [
      spec: layout_builder_t,
      description: """
      Returns a layout or a raw filter graph based on the input/output frame specifications.
      """
    ],
    builder_state: [
      spec: any(),
      default: nil,
      description: """
      Initial state for the filter graph builder.
      """
    ]
  )

  def_input_pad(:primary,
    flow_control: :manual,
    availability: :always,
    demand_unit: :buffers,
    accepted_format: Membrane.RawVideo,
    options: [
      role: [spec: atom(), default: :primary],
      delay: [spec: Membrane.Time.t(), default: 0]
    ]
  )

  def_input_pad(:input,
    flow_control: :manual,
    availability: :on_request,
    demand_unit: :buffers,
    accepted_format: Membrane.RawVideo,
    options: [
      role: [spec: atom()],
      extra_queue_size: [spec: pos_integer(), default: 1]
    ]
  )

  def_output_pad(:output,
    flow_control: :manual,
    availability: :always,
    demand_unit: :buffers,
    accepted_format: Membrane.RawVideo
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      layout_builder: opts.layout_builder,
      builder_state: opts.builder_state,
      mixer: nil,
      layout_choice: nil,
      framerate: nil,
      primary_delay: 0,
      primary_delay_frames: 1,
      queue_by_pad: %{},
      pad_order: [],
      pad_roles: %{},
      extra_queue_size_by_pad: %{},
      spec_by_role: %{},
      last_frame_by_role: %{},
      closed?: false
    }

    state = init_frame_queue(state, :primary)

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    actions =
      state.queue_by_pad
      |> Map.keys()
      |> Enum.map(fn pad -> {:demand, {pad, 1}} end)

    {actions, state}
  end

  @impl true
  def handle_pad_added(pad, ctx, state) do
    state = register_pad_role!(state, pad, ctx)
    state = %{state | mixer: nil, layout_choice: nil}

    actions =
      if ctx.playback == :playing,
        do: [demand: {pad, 1}],
        else: []

    {actions, state}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    role = pad_role!(state, pad)
    state = close_frame_queue(state, pad)
    state = %{state | mixer: nil, layout_choice: nil}
    state = update_in(state, [:pad_roles], &Map.delete(&1, pad))
    state = update_in(state, [:extra_queue_size_by_pad], &Map.delete(&1, pad))
    state = update_in(state, [:spec_by_role], &Map.delete(&1, role))
    state = update_in(state, [:last_frame_by_role], &Map.delete(&1, role))
    mix_if_ready(state)
  end

  @impl true
  def handle_end_of_stream(pad, _ctx, state) do
    state = close_frame_queue(state, pad)
    mix_if_ready(state)
  end

  @impl true
  def handle_stream_format(_pad, %Membrane.RawVideo{framerate: nil}, _ctx, _state) do
    raise "mixer inputs must provide a framerate"
  end

  def handle_stream_format(_pad, %Membrane.RawVideo{framerate: {0, 1}}, _ctx, _state) do
    raise "mixer inputs must provide a stable framerate"
  end

  def handle_stream_format(
        _pad,
        %Membrane.RawVideo{framerate: framerate},
        _ctx,
        %{framerate: target_framerate}
      )
      when framerate != target_framerate and target_framerate != nil do
    raise "all mixer inputs must agree on framerate. Have #{inspect(framerate)}, want #{inspect(target_framerate)}"
  end

  def handle_stream_format(pad, caps = %Membrane.RawVideo{framerate: framerate}, ctx, state) do
    state = ensure_primary_role(state, pad, ctx)
    role = pad_role!(state, pad)
    frame_spec = build_frame_spec(role, caps)
    delay_frames = maybe_update_primary_delay(state, pad, ctx, framerate)

    state =
      state
      |> put_in([:framerate], framerate)
      |> put_in([:primary_delay_frames], delay_frames)
      |> update_in([:queue_by_pad, pad], fn queue ->
        FrameQueue.push(queue, frame_spec)
      end)
      |> update_in([:spec_by_role], &Map.put(&1, role, frame_spec))

    base_actions =
      if pad == :primary do
        [stream_format: {:output, caps}]
      else
        []
      end

    {mix_actions, state} = mix_if_ready(state)
    {base_actions ++ mix_actions, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _context, state) do
    primary_actions =
      case Map.get(state.queue_by_pad, :primary) do
        nil ->
          []

        queue ->
          if FrameQueue.ready?(queue) do
            needed = state.primary_delay_frames - FrameQueue.size(queue)

            if needed > 0 do
              [{:demand, {:primary, needed}}]
            else
              []
            end
          else
            []
          end
      end

    extra_actions =
      state.queue_by_pad
      |> Enum.reject(fn {pad, _queue} -> pad == :primary end)
      |> Enum.filter(fn {_pad, queue} -> FrameQueue.ready?(queue) end)
      |> Enum.reject(fn {_pad, queue} -> FrameQueue.any?(queue) or FrameQueue.closed?(queue) end)
      |> Enum.map(fn {pad, _queue} -> {:demand, {pad, 1}} end)

    {primary_actions ++ extra_actions, state}
  end

  @impl true
  def handle_buffer(pad, buffer, _ctx, state) do
    if master_closed?(state) do
      {[], state}
    else
      frame = %Frame{
        pts: buffer.pts,
        data: buffer.payload,
        size: byte_size(buffer.payload)
      }

      state
      |> update_in([:queue_by_pad, pad], fn queue -> FrameQueue.push(queue, frame) end)
      |> maybe_drop_extra_frames(pad)
      |> mix_if_ready()
    end
  end

  @impl true
  def handle_parent_notification(:rebuild_filter_graph, _ctx, state) do
    {[], %{state | mixer: nil, layout_choice: nil}}
  end

  def handle_parent_notification({:rebuild_filter_graph, builder_state}, _ctx, state) do
    {[], %{state | mixer: nil, layout_choice: nil, builder_state: builder_state}}
  end

  defp master_closed?(state) do
    case get_in(state, [:queue_by_pad, :primary]) do
      nil -> false
      queue -> FrameQueue.closed?(queue)
    end
  end

  defp mix_if_ready(state) do
    # Handle closed queues first. If the primary one is done, that's it.
    if master_closed?(state) and not state.closed? do
      {[end_of_stream: :output], %{state | closed?: true}}
    else
      # delete all inputs that are now closed.
      prev_queues_count = map_size(state.queue_by_pad)

      state =
        state
        |> update_in([:queue_by_pad], fn queue_by_pad ->
          queue_by_pad
          |> Enum.filter(fn {_pad, queue} -> FrameQueue.closed?(queue) end)
          |> Enum.reduce(queue_by_pad, fn {pad, queue}, acc ->
            Membrane.Logger.debug("Deleting closed queue: #{inspect(queue)}")
            Map.delete(acc, pad)
          end)
        end)
        |> then(fn state ->
          update_in(state, [:pad_order], fn pad_order ->
            Enum.filter(pad_order, &Map.has_key?(state.queue_by_pad, &1))
          end)
        end)

      cur_queues_count = map_size(state.queue_by_pad)
      specs_removed? = prev_queues_count != cur_queues_count
      state = if specs_removed?, do: %{state | mixer: nil}, else: state

      primary_queue = Map.get(state.queue_by_pad, :primary)

      if primary_queue == nil or not FrameQueue.ready?(primary_queue) do
        {[], state}
      else
        primary_queue_size = FrameQueue.size(primary_queue)

        if primary_queue_size < state.primary_delay_frames do
          {[], state}
        else
          input_order = input_order(state)

          if Enum.all?(input_order, &Map.has_key?(state.spec_by_role, &1)) do
            {state, buffers} = mix_n(state, 1, [])
            {[buffer: {:output, buffers}, redemand: :output], state}
          else
            {[], state}
          end
        end
      end
    end
  end

  defp mix_n(state, 0, acc), do: {state, Enum.reverse(acc)}

  defp mix_n(state, n, acc) do
    {state, buffer} = mix(state)
    mix_n(state, n - 1, [buffer | acc])
  end

  defp mix(state = %{layout_builder: builder, mixer: mixer}) do
    {frames_with_spec, state} =
      state.pad_order
      |> Enum.filter(&Map.has_key?(state.queue_by_pad, &1))
      |> Enum.map_reduce(state, fn pad, state ->
        queue = state.queue_by_pad[pad]

        if FrameQueue.ready?(queue) and FrameQueue.any?(queue) do
          {value, queue} = FrameQueue.pop!(queue)
          {Map.put(value, :pad, pad), put_in(state, [:queue_by_pad, pad], queue)}
        else
          {nil, state}
        end
      end)

    popped_frames = Enum.reject(frames_with_spec, &is_nil/1)

    specs_changed? =
      popped_frames
      |> Enum.filter(fn %{spec_changed?: x} -> x end)
      |> Enum.any?()

    input_order = input_order(state)
    specs_by_role = state.spec_by_role
    primary_role = pad_role!(state, :primary)
    output_spec = Map.fetch!(specs_by_role, primary_role)

    {layout_choice, state} =
      if mixer == nil or specs_changed? do
        layout_choice =
          case state.layout_choice do
            nil -> builder.(output_spec, specs_by_role, state.builder_state)
            choice -> choice
          end

        {layout_choice, %{state | layout_choice: layout_choice}}
      else
        {state.layout_choice, state}
      end

    mixer =
      if specs_changed? or mixer == nil do
        specs = Enum.map(input_order, &Map.fetch!(specs_by_role, &1))

        case layout_choice do
          {:layout, layout} ->
            {:ok, mixer} = VideoMixer.init(layout, specs_by_role, output_spec)
            mixer

          {:raw, filter_graph} ->
            {:ok, mixer} = VideoMixer.init_raw(filter_graph, specs, input_order, output_spec)
            mixer

          other ->
            raise "invalid layout_builder result: #{inspect(other)}"
        end
      else
        mixer
      end

    {frames_by_name, state} = build_frames_by_role(state, input_order, popped_frames, primary_role)
    primary_frame = Map.fetch!(frames_by_name, primary_role)
    {:ok, raw_frame} = VideoMixer.mix(mixer, Map.to_list(frames_by_name))

    buffer = %Membrane.Buffer{
      payload: raw_frame,
      pts: primary_frame.pts
    }

    {%{state | mixer: mixer}, buffer}
  end

  defp init_frame_queue(state, pad) do
    state
    |> put_in([:queue_by_pad, pad], FrameQueue.new())
    |> update_in([:pad_order], fn pad_order -> pad_order ++ [pad] end)
  end

  defp close_frame_queue(state, pad) do
    case get_in(state, [:queue_by_pad, pad]) do
      nil ->
        # Deleted already.
        state

      _queue ->
        update_in(state, [:queue_by_pad, pad], fn
          queue -> FrameQueue.push(queue, :end_of_stream)
        end)
    end
  end

  defp build_frame_spec(role, caps) do
    %Membrane.RawVideo{width: width, height: height, pixel_format: format} = caps
    {:ok, size} = Membrane.RawVideo.frame_size(format, width, height)

    %FrameSpec{
      reference: role,
      width: width,
      height: height,
      pixel_format: format,
      accepted_frame_size: size
    }
  end

  defp register_pad_role!(state, pad, ctx) do
    if pad == :primary do
      state
    else
    role =
      case ctx.pad_options do
        %{role: role} when is_atom(role) -> role
        _ -> raise "dynamic input pads require :role option"
      end

    if Map.values(state.pad_roles) |> Enum.member?(role) do
      raise "duplicate role #{inspect(role)} for pad #{inspect(pad)}"
    end

    state
    |> init_frame_queue(pad)
    |> update_in([:pad_roles], &Map.put(&1, pad, role))
    |> update_in([:extra_queue_size_by_pad], &Map.put(&1, pad, extra_queue_size(ctx)))
    end
  end

  defp ensure_primary_role(state, :primary, ctx) do
    role =
      ctx.pads
      |> Map.get(:primary, %{})
      |> Map.get(:options, %{})
      |> Map.get(:role, :primary)

    cond do
      Map.has_key?(state.pad_roles, :primary) ->
      state

      Map.values(state.pad_roles) |> Enum.member?(role) ->
        raise "duplicate role #{inspect(role)} for pad :primary"

      true ->
      update_in(state, [:pad_roles], &Map.put(&1, :primary, role))
    end
  end

  defp ensure_primary_role(state, _pad, _ctx), do: state

  defp pad_role!(state, pad) do
    case Map.fetch(state.pad_roles, pad) do
      {:ok, role} -> role
      :error -> raise "missing role for pad #{inspect(pad)}"
    end
  end

  defp input_order(state) do
    state.pad_order
    |> Enum.filter(&Map.has_key?(state.queue_by_pad, &1))
    |> Enum.map(&pad_role!(state, &1))
  end

  defp build_frames_by_role(state, input_order, popped_frames, primary_role) do
    popped_by_role =
      Enum.reduce(popped_frames, %{}, fn %{pad: pad, frame: frame, spec: spec}, acc ->
        role = pad_role!(state, pad)
        Map.put(acc, role, %{frame: frame, spec: spec})
      end)

    {frames_by_name, state} =
      Enum.reduce(input_order, {%{}, state}, fn role, {frames_by_name, state} ->
        case popped_by_role do
          %{^role => %{frame: frame}} ->
            state = update_in(state, [:last_frame_by_role], &Map.put(&1, role, frame))
            {Map.put(frames_by_name, role, frame), state}

          _ ->
            frame = fallback_frame(state, role, frames_by_name[primary_role])
            {Map.put(frames_by_name, role, frame), state}
        end
      end)

    {frames_by_name, state}
  end

  defp fallback_frame(state, role, primary_frame) do
    case Map.fetch(state.last_frame_by_role, role) do
      {:ok, frame} -> frame
      :error -> black_frame(state, role, primary_frame)
    end
  end

  defp black_frame(state, role, %Frame{pts: pts}) do
    spec = Map.fetch!(state.spec_by_role, role)
    payload = black_payload(spec)

    %Frame{
      data: payload,
      pts: pts,
      size: byte_size(payload)
    }
  end

  defp black_payload(%FrameSpec{pixel_format: :I420, width: width, height: height}) do
    y_plane = :binary.copy(<<0>>, width * height)
    uv_size = div(width * height, 4)
    u_plane = :binary.copy(<<128>>, uv_size)
    v_plane = :binary.copy(<<128>>, uv_size)
    y_plane <> u_plane <> v_plane
  end

  defp black_payload(%FrameSpec{pixel_format: _format, accepted_frame_size: size}) do
    :binary.copy(<<0>>, size)
  end

  defp maybe_update_primary_delay(state, :primary, ctx, framerate) do
    delay =
      ctx.pads
      |> Map.get(:primary, %{})
      |> Map.get(:options, %{})
      |> Map.get(:delay, state.primary_delay)

    delay_to_frames(delay, framerate)
  end

  defp maybe_update_primary_delay(state, _pad, _ctx, _framerate), do: state.primary_delay_frames

  defp delay_to_frames(delay, {frames, seconds}) do
    if delay <= 0 do
      1
    else
      numerator = delay * frames
      denominator = seconds * Membrane.Time.second()
      div(numerator + denominator - 1, denominator)
    end
  end

  defp extra_queue_size(ctx) do
    case ctx.pad_options do
      %{extra_queue_size: size} when is_integer(size) and size > 0 -> size
      _ -> 1
    end
  end

  defp maybe_drop_extra_frames(state, :primary), do: state

  defp maybe_drop_extra_frames(state, pad) do
    if primary_stalled?(state) do
      limit = Map.get(state.extra_queue_size_by_pad, pad, 1)
      queue = Map.get(state.queue_by_pad, pad)
      trimmed_queue = drop_oldest_ready(queue, limit)
      put_in(state, [:queue_by_pad, pad], trimmed_queue)
    else
      state
    end
  end

  defp drop_oldest_ready(queue, limit) do
    if FrameQueue.size(queue) > limit do
      {_dropped, queue} = FrameQueue.pop!(queue)
      drop_oldest_ready(queue, limit)
    else
      queue
    end
  end

  defp primary_stalled?(state) do
    case Map.get(state.queue_by_pad, :primary) do
      nil -> true
      queue -> not FrameQueue.ready?(queue)
    end
  end
end
