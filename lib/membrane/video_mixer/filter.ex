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
          (output_spec :: FrameSpec.t(),
           inputs :: %{atom() => FrameSpec.t()},
           builder_state :: any ->
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
      delay: [spec: Membrane.Time.t(), default: 0],
      fit_mode: [spec: :crop | :fit, default: :crop]
    ]
  )

  def_input_pad(:input,
    flow_control: :manual,
    availability: :on_request,
    demand_unit: :buffers,
    accepted_format: Membrane.RawVideo,
    options: [
      role: [spec: atom()],
      extra_queue_size: [spec: pos_integer(), default: 1],
      fit_mode: [spec: :crop | :fit, default: :crop]
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
      mixer_specs: nil,
      layout_choice: nil,
      framerate: nil,
      primary_delay: 0,
      primary_delay_frames: 1,
      queue_by_pad: %{},
      pad_order: [],
      pad_roles: %{},
      fit_mode_by_pad: %{},
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
    state = %{state | mixer: nil, mixer_specs: nil, layout_choice: nil}

    actions =
      if ctx.playback == :playing,
        do: [demand: {pad, 1}],
        else: []

    {actions, state}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    role = pad_role!(state, pad)

    state =
      state
      |> update_in([:queue_by_pad], &Map.delete(&1, pad))
      |> update_in([:pad_order], &Enum.reject(&1, fn entry -> entry == pad end))
      |> update_in([:pad_roles], &Map.delete(&1, pad))
      |> update_in([:fit_mode_by_pad], &Map.delete(&1, pad))
      |> update_in([:extra_queue_size_by_pad], &Map.delete(&1, pad))
      |> update_in([:spec_by_role], &Map.delete(&1, role))
      |> update_in([:last_frame_by_role], &Map.delete(&1, role))
      |> then(&%{&1 | mixer: nil, mixer_specs: nil, layout_choice: nil})

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
    frame_spec = build_frame_spec(state, role, pad, caps)
    delay_frames = maybe_update_primary_delay(state, pad, ctx, framerate)

    # Check if spec changed to clear cached last_frame
    old_spec = Map.get(state.spec_by_role, role)
    spec_changed? = old_spec != nil and old_spec.accepted_frame_size != frame_spec.accepted_frame_size

    state =
      state
      |> put_in([:framerate], framerate)
      |> put_in([:primary_delay_frames], delay_frames)
      |> update_in([:queue_by_pad, pad], fn queue ->
        FrameQueue.push(queue, frame_spec)
      end)
      |> update_in([:spec_by_role], &Map.put(&1, role, frame_spec))
      |> then(&%{&1 | mixer: nil, mixer_specs: nil, layout_choice: nil})
      |> then(fn s ->
        if spec_changed?, do: update_in(s, [:last_frame_by_role], &Map.delete(&1, role)), else: s
      end)

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

      state =
        state
        |> update_in([:queue_by_pad, pad], fn queue -> FrameQueue.push(queue, frame) end)
        |> maybe_drop_extra_frames(pad)

      {actions, state} = mix_if_ready(state)

      actions =
        if pad == :primary do
          actions
        else
          actions ++ [demand: {pad, 1}]
        end

      {actions, state}
    end
  end

  @impl true
  def handle_parent_notification(:rebuild_filter_graph, _ctx, state) do
    {[], %{state | mixer: nil, mixer_specs: nil, layout_choice: nil}}
  end

  def handle_parent_notification({:rebuild_filter_graph, builder_state}, _ctx, state) do
    {[], %{state | mixer: nil, mixer_specs: nil, layout_choice: nil, builder_state: builder_state}}
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
          # Clean up roles for deleted pads
          deleted_pads =
            state.pad_order
            |> Enum.reject(&Map.has_key?(state.queue_by_pad, &1))

          Enum.reduce(deleted_pads, state, fn pad, state ->
            case Map.get(state.pad_roles, pad) do
              nil -> state
              role ->
                state
                |> update_in([:spec_by_role], &Map.delete(&1, role))
                |> update_in([:last_frame_by_role], &Map.delete(&1, role))
            end
          end)
        end)
        |> then(fn state ->
          update_in(state, [:pad_order], fn pad_order ->
            Enum.filter(pad_order, &Map.has_key?(state.queue_by_pad, &1))
          end)
        end)

      cur_queues_count = map_size(state.queue_by_pad)
      specs_removed? = prev_queues_count != cur_queues_count
      state = if specs_removed?, do: %{state | mixer: nil, mixer_specs: nil}, else: state

      primary_queue = Map.get(state.queue_by_pad, :primary)

      if primary_queue == nil or not FrameQueue.ready?(primary_queue) do
        {[], state}
      else
        primary_queue_size = FrameQueue.size(primary_queue)

        if primary_queue_size < state.primary_delay_frames do
          {[], state}
        else
          primary_role = pad_role!(state, :primary)
          output_spec = Map.get(state.spec_by_role, primary_role)

          if output_spec == nil do
            {[], state}
          else
            {layout_choice, state} = ensure_layout_choice(state, output_spec, false)
            required_roles = required_roles(layout_choice, input_order(state))

            if Enum.all?(required_roles, &Map.has_key?(state.spec_by_role, &1)) do
              {state, buffers} = mix_n(state, 1, [])
              {[buffer: {:output, buffers}, redemand: :output], state}
            else
              {[], state}
            end
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

  defp mix(state = %{mixer: mixer}) do
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

    # Build specs from POPPED FRAMES (not spec_by_role)
    specs_from_popped =
      Enum.reduce(popped_frames, %{}, fn %{pad: pad, spec: spec}, acc ->
        role = pad_role!(state, pad)
        Map.put(acc, role, spec)
      end)

    input_order = input_order(state)
    primary_role = pad_role!(state, :primary)
    # Use popped frame spec if available, fallback to spec_by_role
    output_spec = Map.get(specs_from_popped, primary_role) || Map.fetch!(state.spec_by_role, primary_role)

    {layout_choice, state} = ensure_layout_choice(state, output_spec, mixer == nil)
    required_roles = required_roles(layout_choice, input_order)

    # Use popped frame spec if available, fallback to spec_by_role for roles without frames
    specs_for_mixer =
      Enum.reduce(required_roles, %{}, fn role, acc ->
        spec = Map.get(specs_from_popped, role) || Map.get(state.spec_by_role, role)
        if spec, do: Map.put(acc, role, spec), else: acc
      end)

    # Rebuild mixer if specs changed from what mixer was built with
    mixer_specs_changed? = mixer != nil and mixer_specs_differ?(state.mixer_specs, specs_for_mixer)

    {mixer, state} =
      if mixer_specs_changed? or mixer == nil do
        specs = Enum.map(required_roles, &Map.fetch!(specs_for_mixer, &1))

        new_mixer =
          case layout_choice do
            {:layout, layout} ->
              {:ok, mixer} = VideoMixer.init(layout, specs_for_mixer, output_spec)
              mixer

            {:raw, filter_graph} ->
              {:ok, mixer} = VideoMixer.init_raw(filter_graph, specs, required_roles, output_spec)
              mixer

            other ->
              raise "invalid layout_builder result: #{inspect(other)}"
          end

        {new_mixer, %{state | mixer_specs: specs_for_mixer}}
      else
        {mixer, state}
      end

    {frames_by_name, state} =
      build_frames_by_role(state, required_roles, popped_frames, primary_role, specs_for_mixer)

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

  defp build_frame_spec(state, role, pad, caps) do
    %Membrane.RawVideo{width: width, height: height, pixel_format: format} = caps
    {:ok, size} = Membrane.RawVideo.frame_size(format, width, height)
    fit_mode = Map.get(state.fit_mode_by_pad, pad, :crop)

    %FrameSpec{
      reference: role,
      width: width,
      height: height,
      pixel_format: format,
      accepted_frame_size: size,
      fit_mode: fit_mode
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

      fit_mode = Map.get(ctx.pad_options, :fit_mode, :crop)

      if Map.values(state.pad_roles) |> Enum.member?(role) do
        raise "duplicate role #{inspect(role)} for pad #{inspect(pad)}"
      end

      state
      |> init_frame_queue(pad)
      |> update_in([:pad_roles], &Map.put(&1, pad, role))
      |> update_in([:fit_mode_by_pad], &Map.put(&1, pad, fit_mode))
      |> update_in([:extra_queue_size_by_pad], &Map.put(&1, pad, extra_queue_size(ctx)))
    end
  end

  defp ensure_primary_role(state, :primary, ctx) do
    primary_options =
      ctx.pads
      |> Map.get(:primary, %{})
      |> Map.get(:options, %{})

    role = Map.get(primary_options, :role, :primary)
    fit_mode = Map.get(primary_options, :fit_mode, :crop)

    cond do
      Map.has_key?(state.pad_roles, :primary) ->
        state

      Map.values(state.pad_roles) |> Enum.member?(role) ->
        raise "duplicate role #{inspect(role)} for pad :primary"

      true ->
        state
        |> update_in([:pad_roles], &Map.put(&1, :primary, role))
        |> update_in([:fit_mode_by_pad], &Map.put(&1, :primary, fit_mode))
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
    |> Enum.filter(&Map.has_key?(state.pad_roles, &1))
    |> Enum.map(&pad_role!(state, &1))
  end

  defp build_frames_by_role(state, input_order, popped_frames, primary_role, specs_for_mixer) do
    popped_by_role =
      Enum.reduce(popped_frames, %{}, fn %{pad: pad, frame: frame, spec: spec}, acc ->
        role = pad_role!(state, pad)
        Map.put(acc, role, %{frame: frame, spec: spec})
      end)

    state =
      Enum.reduce(popped_frames, state, fn %{pad: pad, frame: frame}, state ->
        role = pad_role!(state, pad)
        update_in(state, [:last_frame_by_role], &Map.put(&1, role, frame))
      end)

    {frames_by_name, state} =
      Enum.reduce(input_order, {%{}, state}, fn role, {frames_by_name, state} ->
        case popped_by_role do
          %{^role => %{frame: frame}} ->
            {Map.put(frames_by_name, role, frame), state}

          _ ->
            frame = fallback_frame(state, role, frames_by_name[primary_role], specs_for_mixer)
            {Map.put(frames_by_name, role, frame), state}
        end
      end)

    {frames_by_name, state}
  end

  defp fallback_frame(state, role, primary_frame, specs_for_mixer) do
    case Map.fetch(state.last_frame_by_role, role) do
      {:ok, frame} -> frame
      :error -> black_frame(role, primary_frame, specs_for_mixer)
    end
  end

  defp black_frame(role, %Frame{pts: pts}, specs_for_mixer) do
    spec = Map.fetch!(specs_for_mixer, role)
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

  defp ensure_layout_choice(state = %{layout_builder: builder}, output_spec, force?) do
    if force? or state.layout_choice == nil do
      layout_choice = builder.(output_spec, state.spec_by_role, state.builder_state)
      {layout_choice, %{state | layout_choice: layout_choice}}
    else
      {state.layout_choice, state}
    end
  end

  defp required_roles({:layout, layout}, _input_order), do: layout_roles(layout)
  defp required_roles({:raw, _filter_graph}, input_order), do: input_order

  defp required_roles(other, _input_order),
    do: raise("invalid layout_builder result: #{inspect(other)}")

  defp specs_for_roles(specs_by_role, roles) do
    Map.take(specs_by_role, roles)
  end

  defp mixer_specs_differ?(mixer_specs, _specs_for_mixer) when mixer_specs == nil, do: true

  defp mixer_specs_differ?(mixer_specs, specs_for_mixer) do
    # Check if any spec in specs_for_mixer has a different accepted_frame_size than mixer_specs
    map_size(mixer_specs) != map_size(specs_for_mixer) or
      Enum.any?(specs_for_mixer, fn {role, spec} ->
        case Map.get(mixer_specs, role) do
          nil -> true
          mixer_spec -> mixer_spec.accepted_frame_size != spec.accepted_frame_size
        end
      end)
  end

  defp layout_roles(:single_fit), do: [:primary]
  defp layout_roles(:hstack), do: [:left, :right]
  defp layout_roles(:vstack), do: [:top, :bottom]
  defp layout_roles(:xstack), do: [:top_left, :top_right, :bottom_left, :bottom_right]
  defp layout_roles(:primary_sidebar), do: [:primary, :sidebar]

  defp layout_roles(other),
    do: raise("invalid layout_builder result: #{inspect(other)}")

  defp maybe_drop_extra_frames(state, :primary), do: state

  defp maybe_drop_extra_frames(state, pad) do
    if primary_needs_frames?(state) do
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

  defp primary_needs_frames?(state) do
    case Map.get(state.queue_by_pad, :primary) do
      nil -> true
      queue -> FrameQueue.size(queue) < state.primary_delay_frames
    end
  end
end
