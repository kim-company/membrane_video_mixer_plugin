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
           inputs :: %{any() => FrameSpec.t()},
           builder_state :: any ->
             {:layout, VideoMixer.FilterGraph.layout()}
             | {:layout, VideoMixer.FilterGraph.layout(), slot_mapping :: %{atom() => any()}}
             | {:raw, VideoMixer.filter_graph_t()})

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
    flow_control: :auto,
    availability: :always,
    accepted_format: Membrane.RawVideo,
    options: [
      role: [spec: atom(), default: :primary],
      fit_mode: [spec: :crop | :fit, default: :crop]
    ]
  )

  def_input_pad(:input,
    flow_control: :auto,
    availability: :on_request,
    accepted_format: Membrane.RawVideo,
    options: [
      role: [spec: any(), default: nil],
      fit_mode: [spec: :crop | :fit, default: :crop]
    ]
  )

  def_output_pad(:output,
    flow_control: :auto,
    availability: :always,
    accepted_format: Membrane.RawVideo
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      layout_builder: opts.layout_builder,
      builder_state: opts.builder_state,
      mixer: nil,
      layout_choice: nil,
      slot_mapping: %{},
      framerate: nil,
      queue_by_pad: %{},
      pad_order: [],
      pad_roles: %{},
      fit_mode_by_pad: %{},
      closed?: false
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(pad, ctx, state) do
    state = register_pad_role!(state, pad, ctx)
    {[], state}
  end

  @impl true
  def handle_pad_removed(_pad, _ctx, state) do
    # A pad receives first the end_of_stream and then its removed. We don't have
    # to worry about it now, we're going to handle pad removal once we pop the
    # end_of_stream message from pad's frame queue.
    {[], state}
  end

  @impl true
  def handle_end_of_stream(pad, _ctx, state) do
    state = close_frame_queue(state, pad)
    mix_or_drain(state)
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

    state =
      state
      |> put_in([:framerate], framerate)
      |> update_in([:queue_by_pad, pad], &FrameQueue.push(&1, frame_spec))

    # Stream format will be emitted by mix/2 when popping from primary with spec_changed? == true
    {[], state}
  end

  @impl true
  def handle_buffer(pad, buffer, ctx, state) do
    # Ignore whatever we receive after we've sent end_of_stream
    if stream_finished?(ctx) do
      {[], state}
    else
      frame = %Frame{pts: buffer.pts, data: buffer.payload, size: byte_size(buffer.payload)}

      # Check if pad was ready before pushing
      old_queue = state.queue_by_pad[pad]
      was_ready = FrameQueue.ready?(old_queue)

      state = update_in(state, [:queue_by_pad, pad], &FrameQueue.push(&1, frame))

      # If this pad just became ready (received first frame), reset mixer state
      # so layout is rebuilt to include this pad
      queue = state.queue_by_pad[pad]

      state =
        if not was_ready and FrameQueue.ready?(queue), do: reset_mixer_state(state), else: state

      mix_or_drain(state)
    end
  end

  @impl true
  def handle_parent_notification(:rebuild_filter_graph, _ctx, state) do
    {[], %{state | mixer: nil, layout_choice: nil}}
  end

  def handle_parent_notification({:rebuild_filter_graph, builder_state}, _ctx, state) do
    {[], %{state | mixer: nil, layout_choice: nil, builder_state: builder_state}}
  end

  defp stream_finished?(ctx) do
    ctx.pads.output.end_of_stream?
  end

  defp primary_closed?(state) do
    case get_in(state, [:queue_by_pad, :primary]) do
      nil -> false
      queue -> FrameQueue.closed?(queue)
    end
  end

  defp all_have_frames?(pads, state) do
    Enum.all?(pads, fn pad ->
      queue = Map.get(state.queue_by_pad, pad)
      queue != nil and FrameQueue.any?(queue)
    end)
  end

  defp required_pads(layout_choice, state) do
    required_roles = required_roles(layout_choice, input_order(state), state)

    Enum.map(required_roles, fn role ->
      Enum.find(state.pad_roles, fn {_pad, r} -> r == role end) |> elem(0)
    end)
  end

  defp get_active_pads(state) do
    state.queue_by_pad
    |> Enum.filter(fn {_pad, queue} ->
      FrameQueue.ready?(queue) and not FrameQueue.closed?(queue)
    end)
    |> Enum.map(fn {pad, _} -> pad end)
  end

  defp drain_non_required(state, required_pads) do
    required_set = MapSet.new(required_pads)

    state.queue_by_pad
    |> Enum.reject(fn {pad, _} -> MapSet.member?(required_set, pad) end)
    |> Enum.reduce(state, fn {pad, _}, state ->
      drain_queue_completely(state, pad)
    end)
  end

  defp drain_queue_completely(state, pad) do
    queue = state.queue_by_pad[pad]

    if FrameQueue.any?(queue) do
      {_dropped, queue} = FrameQueue.pop!(queue)
      state = put_in(state, [:queue_by_pad, pad], queue)
      drain_queue_completely(state, pad)
    else
      state
    end
  end

  defp build_specs_from_pads(state, pads) do
    pads
    |> Enum.map(fn pad ->
      queue = state.queue_by_pad[pad]
      role = pad_role!(state, pad)
      {role, queue.current_spec}
    end)
    |> Enum.reject(fn {_role, spec} -> spec == nil end)
    |> Map.new()
  end

  defp spec_to_raw_video(spec, framerate) do
    %Membrane.RawVideo{
      width: spec.width,
      height: spec.height,
      pixel_format: spec.pixel_format,
      framerate: framerate,
      aligned: true
    }
  end

  defp any_spec_changed?(popped_by_pad) do
    Enum.any?(popped_by_pad, fn {_pad, popped} -> popped.spec_changed? end)
  end

  defp pop_from_all(required_pads, state) do
    Enum.reduce(required_pads, {%{}, state}, fn pad, {acc, state} ->
      {popped, queue} = FrameQueue.pop!(state.queue_by_pad[pad])
      state = put_in(state, [:queue_by_pad, pad], queue)
      {Map.put(acc, pad, popped), state}
    end)
  end

  defp mix_or_drain(state) do
    cond do
      # Already sent end_of_stream, don't send again
      state.closed? ->
        {[], state}

      # Primary closed -> end stream
      primary_closed?(state) ->
        {[end_of_stream: :output], %{state | closed?: true}}

      true ->
        {actions, state} = mix(state, [])
        {actions, prune_closed_pads(state)}
    end
  end

  defp mix(state, acc_actions) do
    # 1. Get active pads (ready? and not closed?)
    active_pads = get_active_pads(state)

    # 2. Ensure layout exists (build from current_spec if nil)
    #    Returns nil if we can't build a layout (no active pads with specs)
    case ensure_layout(state, active_pads) do
      {nil, state, _actions} ->
        # Can't build layout yet, nothing to mix
        {acc_actions, state}

      {layout_choice, state, layout_actions} ->
        # 3. Get required pads from layout
        required_pads = required_pads(layout_choice, state)

        # 4. Drain completely all queues NOT in required_pads
        state = drain_non_required(state, required_pads)

        # 5. Check if all required have frames
        if not all_have_frames?(required_pads, state) do
          {acc_actions ++ layout_actions, state}
        else
          # 6. Pop from all required pads
          {popped_by_pad, state} = pop_from_all(required_pads, state)

          # 7. Check if any spec changed
          specs_changed? = any_spec_changed?(popped_by_pad)

          # 8. If primary's spec changed, emit new stream_format
          primary_spec_changed? = popped_by_pad[:primary] && popped_by_pad[:primary].spec_changed?

          stream_format_action =
            if primary_spec_changed? do
              primary_spec = popped_by_pad[:primary].spec
              [stream_format: {:output, spec_to_raw_video(primary_spec, state.framerate)}]
            else
              []
            end

          # 9. Do actual mixing (rebuilds mixer if specs_changed? or mixer is nil)
          #    Uses current layout_choice which is still valid
          {state, buffer} = do_mix(state, popped_by_pad, specs_changed?)

          # 10. AFTER mixing: if specs changed, reset layout for NEXT iteration
          #     This invalidates layout_choice so it's rebuilt from (potentially changed) active pads
          #     Also invalidates mixer so it's rebuilt with the new layout
          state = if specs_changed?, do: reset_mixer_state(state), else: state

          # 11. Accumulate actions and recurse
          new_actions = layout_actions ++ stream_format_action ++ [buffer: {:output, buffer}]
          mix(state, acc_actions ++ new_actions)
        end
    end
  end

  defp do_mix(state, popped_by_pad, specs_changed?) do
    # Build specs and frames maps
    frames_by_role =
      Map.new(popped_by_pad, fn {pad, p} ->
        {pad_role!(state, pad), p.frame}
      end)

    specs_by_role =
      Map.new(popped_by_pad, fn {pad, p} ->
        {pad_role!(state, pad), p.spec}
      end)

    primary_role = pad_role!(state, :primary)
    output_spec = Map.fetch!(specs_by_role, primary_role)

    # Rebuild mixer if needed
    mixer =
      if specs_changed? or state.mixer == nil do
        required_pads = Map.keys(popped_by_pad)

        case state.layout_choice do
          {:layout, layout} ->
            # Normalize role names to match VideoMixer expectations
            normalized_specs = normalize_specs_for_layout(specs_by_role, layout, state)
            {:ok, m} = VideoMixer.init(layout, normalized_specs, output_spec)
            m

          {:raw, filter_graph} ->
            specs = Enum.map(required_pads, &Map.fetch!(specs_by_role, pad_role!(state, &1)))
            roles = Enum.map(required_pads, &pad_role!(state, &1))
            {:ok, m} = VideoMixer.init_raw(filter_graph, specs, roles, output_spec)
            m
        end
      else
        state.mixer
      end

    # Normalize frames_by_role to match VideoMixer expectations
    normalized_frames =
      case state.layout_choice do
        {:layout, layout} ->
          normalize_frames_for_layout(frames_by_role, layout, state)

        {:raw, _} ->
          frames_by_role
      end

    case VideoMixer.mix(mixer, Map.to_list(normalized_frames)) do
      {:ok, raw_frame} ->
        buffer = %Membrane.Buffer{payload: raw_frame, pts: frames_by_role[primary_role].pts}
        {%{state | mixer: mixer}, buffer}

      {:error, error} ->
        require Logger

        Logger.error(
          "VideoMixer.mix failed: #{inspect(error)}. " <>
            "This should not happen as frames are validated before queuing. " <>
            "Rebuilding mixer on next frame."
        )

        # Force mixer rebuild on next frame
        raise "VideoMixer.mix failed with frame spec mismatch. " <>
                "Frames: #{inspect(Map.keys(frames_by_role))}, " <>
                "Specs: #{inspect(specs_by_role)}, " <>
                "Error: #{inspect(error)}"
    end
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

  defp prune_closed_pads(state) do
    {state, removed?} =
      state.queue_by_pad
      |> Enum.reduce({state, false}, fn {pad, queue}, {state, removed?} ->
        if FrameQueue.closed?(queue) do
          new_state =
            state
            |> update_in([:queue_by_pad], &Map.delete(&1, pad))
            |> update_in([:pad_roles], &Map.delete(&1, pad))
            |> update_in([:fit_mode_by_pad], &Map.delete(&1, pad))
            |> update_in([:pad_order], &Enum.reject(&1, fn item -> item == pad end))

          {new_state, true}
        else
          {state, removed?}
        end
      end)

    if removed?, do: reset_mixer_state(state), else: state
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
    role =
      case ctx.pad_options do
        %{role: role} when not is_nil(role) -> role
        _ -> pad_id(pad)
      end

    fit_mode = Map.get(ctx.pad_options, :fit_mode, :crop)

    if Map.values(state.pad_roles) |> Enum.member?(role) do
      raise "duplicate role #{inspect(role)} for pad #{inspect(pad)}"
    end

    state
    |> init_frame_queue(pad)
    |> update_in([:pad_roles], &Map.put(&1, pad, role))
    |> update_in([:fit_mode_by_pad], &Map.put(&1, pad, fit_mode))
  end

  defp pad_id(Membrane.Pad.ref(:input, id)), do: id

  defp ensure_primary_role(state, :primary, ctx) do
    pad_options = ctx.pads.primary.options
    role = Map.get(pad_options, :role, :primary)
    fit_mode = Map.get(pad_options, :fit_mode, :crop)

    cond do
      Map.has_key?(state.pad_roles, :primary) ->
        state

      Map.values(state.pad_roles) |> Enum.member?(role) ->
        raise "duplicate role #{inspect(role)} for pad :primary"

      true ->
        state
        |> init_frame_queue(:primary)
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

  defp ensure_layout(state, active_pads) do
    cond do
      # Use cached layout if available
      state.layout_choice != nil ->
        {state.layout_choice, state, []}

      # Can't build layout without active pads with specs
      active_pads == [] ->
        {nil, state, []}

      # Can't build layout if primary role not registered yet
      not Map.has_key?(state.pad_roles, :primary) ->
        {nil, state, []}

      true ->
        specs_by_role = build_specs_from_pads(state, active_pads)
        primary_role = pad_role!(state, :primary)

        case Map.fetch(specs_by_role, primary_role) do
          {:ok, output_spec} ->
            case state.layout_builder.(output_spec, specs_by_role, state.builder_state) do
              {:layout, layout, slot_mapping} ->
                validate_slot_mapping!(layout, slot_mapping, specs_by_role)
                layout_choice = {:layout, layout}
                new_state = %{state | layout_choice: layout_choice, slot_mapping: slot_mapping}
                notification = build_layout_notification(layout_choice, new_state, active_pads)
                {layout_choice, new_state, [notify_parent: notification]}

              {:layout, layout} ->
                layout_choice = {:layout, layout}
                new_state = %{state | layout_choice: layout_choice, slot_mapping: %{}}
                notification = build_layout_notification(layout_choice, new_state, active_pads)
                {layout_choice, new_state, [notify_parent: notification]}

              {:raw, _} = raw ->
                new_state = %{state | layout_choice: raw, slot_mapping: %{}}
                notification = build_layout_notification(raw, new_state, active_pads)
                {raw, new_state, [notify_parent: notification]}
            end

          :error ->
            # Primary doesn't have a spec yet
            {nil, state, []}
        end
    end
  end

  defp reset_mixer_state(state) do
    state
    |> put_in([:mixer], nil)
    |> put_in([:layout_choice], nil)
    |> put_in([:slot_mapping], %{})
  end

  defp build_layout_notification({:layout, layout}, state, active_pads) do
    # Build reverse mapping: role -> slot
    role_to_slot =
      layout_slot_order(layout, state)
      |> Enum.map(fn slot ->
        role = resolve_slot(slot, state)
        {role, slot}
      end)
      |> Map.new()

    # Build pad -> slot mapping for active pads (nil if not in layout)
    slots =
      active_pads
      |> Enum.map(fn pad ->
        role = pad_role!(state, pad)
        slot = Map.get(role_to_slot, role)
        {pad, slot}
      end)
      |> Map.new()

    {:layout_updated, %{layout: layout, slots: slots}}
  end

  defp build_layout_notification({:raw, _filter_graph}, _state, active_pads) do
    # For raw filter graphs, all pads participate but no slot names
    slots =
      active_pads
      |> Enum.map(fn pad -> {pad, nil} end)
      |> Map.new()

    {:layout_updated, %{layout: :raw, slots: slots}}
  end

  defp layout_slot_order(:single_fit, _state), do: [:primary]
  defp layout_slot_order(:hstack, _state), do: [:left, :right]
  defp layout_slot_order(:vstack, _state), do: [:top, :bottom]

  defp layout_slot_order(:xstack, _state),
    do: [:top_left, :top_right, :bottom_left, :bottom_right]

  defp layout_slot_order(:primary_sidebar, _state), do: [:primary, :sidebar]

  defp layout_slot_order(other, _state),
    do: raise("invalid layout: #{inspect(other)}")

  defp resolve_slot(slot_name, state) do
    case Map.get(state.slot_mapping, slot_name) do
      nil ->
        # No mapping - default behavior
        if slot_name == :primary, do: pad_role!(state, :primary), else: slot_name

      user_role ->
        user_role
    end
  end

  defp validate_slot_mapping!(layout, slot_mapping, specs_by_role) do
    available_roles = Map.keys(specs_by_role)
    valid_slots = layout_slot_order(layout, nil)

    Enum.each(slot_mapping, fn {slot, role} ->
      unless slot in valid_slots do
        raise "invalid slot #{inspect(slot)} for layout #{inspect(layout)}. Valid slots: #{inspect(valid_slots)}"
      end

      unless role in available_roles do
        raise "slot mapping #{inspect(slot)} -> #{inspect(role)} refers to unavailable role. Available: #{inspect(available_roles)}"
      end
    end)
  end

  defp required_roles({:layout, layout}, _input_order, state), do: layout_roles(layout, state)
  defp required_roles({:raw, _filter_graph}, input_order, _state), do: input_order

  defp required_roles(other, _input_order, _state),
    do: raise("invalid layout_builder result: #{inspect(other)}")

  defp layout_roles(:single_fit, state), do: [resolve_slot(:primary, state)]
  defp layout_roles(:hstack, state), do: [resolve_slot(:left, state), resolve_slot(:right, state)]
  defp layout_roles(:vstack, state), do: [resolve_slot(:top, state), resolve_slot(:bottom, state)]

  defp layout_roles(:xstack, state) do
    [
      resolve_slot(:top_left, state),
      resolve_slot(:top_right, state),
      resolve_slot(:bottom_left, state),
      resolve_slot(:bottom_right, state)
    ]
  end

  defp layout_roles(:primary_sidebar, state) do
    [resolve_slot(:primary, state), resolve_slot(:sidebar, state)]
  end

  defp layout_roles(other, _state),
    do: raise("invalid layout_builder result: #{inspect(other)}")

  # Normalize role names to match VideoMixer's expectations for preset layouts
  defp normalize_specs_for_layout(specs_by_role, layout, state) do
    layout_slot_order(layout, state)
    |> Enum.map(fn slot_name ->
      user_role = resolve_slot(slot_name, state)
      {slot_name, Map.fetch!(specs_by_role, user_role)}
    end)
    |> Map.new()
  end

  # Normalize frame role names to match VideoMixer's expectations
  defp normalize_frames_for_layout(frames_by_role, layout, state) do
    layout_slot_order(layout, state)
    |> Enum.map(fn slot_name ->
      user_role = resolve_slot(slot_name, state)
      {slot_name, Map.fetch!(frames_by_role, user_role)}
    end)
    |> Map.new()
  end
end
