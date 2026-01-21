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
      layout_choice: nil,
      framerate: nil,
      queue_by_pad: %{},
      pad_order: [],
      pad_roles: %{},
      fit_mode_by_pad: %{},
      active_pads: MapSet.new(),
      spec_by_role: %{},
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
      |> update_in([:active_pads], &MapSet.delete(&1, pad))
      |> update_in([:spec_by_role], &Map.delete(&1, role))
      |> then(&%{&1 | mixer: nil, layout_choice: nil})

    mix_or_drain(state)
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
      |> put_in([:spec_by_role, role], frame_spec)
      |> update_in([:queue_by_pad, pad], &FrameQueue.push(&1, frame_spec))

    base_actions = if pad == :primary, do: [stream_format: {:output, caps}], else: []
    {mix_actions, state} = mix_or_drain(state)
    {base_actions ++ mix_actions, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _context, state) do
    actions =
      state.queue_by_pad
      |> Enum.reject(fn {_pad, queue} -> FrameQueue.any?(queue) or FrameQueue.closed?(queue) end)
      |> Enum.map(fn {pad, _queue} -> {:demand, {pad, 1}} end)

    {actions, state}
  end

  @impl true
  def handle_buffer(pad, buffer, _ctx, state) do
    if primary_closed?(state) do
      {[], state}
    else
      # Validate frame size matches current spec to avoid mismatches when resolution changes
      role = pad_role!(state, pad)
      current_spec = Map.get(state.spec_by_role, role)
      frame_size = byte_size(buffer.payload)

      cond do
        # No spec yet - queue the frame (first frame before stream_format)
        current_spec == nil ->
          frame = %Frame{pts: buffer.pts, data: buffer.payload, size: frame_size}
          state = update_in(state, [:queue_by_pad, pad], &FrameQueue.push(&1, frame))

          # Pad becomes "active" on first frame
          was_active = MapSet.member?(state.active_pads, pad)
          state = update_in(state.active_pads, &MapSet.put(&1, pad))

          # Rebuild layout if pad just became active
          state = if not was_active, do: %{state | mixer: nil, layout_choice: nil}, else: state

          {actions, state} = mix_or_drain(state)

          # Always redemand from the pad that sent us the buffer (keeps upstream flowing)
          demand_action = if pad != :primary, do: [demand: {pad, 1}], else: []
          {actions ++ demand_action, state}

        # Frame size doesn't match current spec - drop it and demand another
        # This can happen when a pad is removed and re-added with different resolution,
        # and there are buffered frames from the old resolution still in flight
        frame_size != current_spec.accepted_frame_size ->
          require Logger

          Logger.warning(
            "Dropping frame from #{inspect(pad)} (role: #{inspect(role)}): " <>
              "frame size #{frame_size} doesn't match expected size #{current_spec.accepted_frame_size} " <>
              "(spec: #{current_spec.width}x#{current_spec.height})"
          )

          # Just demand another frame
          demand_action = if pad != :primary, do: [demand: {pad, 1}], else: []
          {demand_action, state}

        # Frame size matches - proceed normally
        true ->
          frame = %Frame{pts: buffer.pts, data: buffer.payload, size: frame_size}
          state = update_in(state, [:queue_by_pad, pad], &FrameQueue.push(&1, frame))

          # Pad becomes "active" on first frame
          was_active = MapSet.member?(state.active_pads, pad)
          state = update_in(state.active_pads, &MapSet.put(&1, pad))

          # Rebuild layout if pad just became active
          state = if not was_active, do: %{state | mixer: nil, layout_choice: nil}, else: state

          {actions, state} = mix_or_drain(state)

          # Always redemand from the pad that sent us the buffer (keeps upstream flowing)
          demand_action = if pad != :primary, do: [demand: {pad, 1}], else: []
          {actions ++ demand_action, state}
      end
    end
  end

  @impl true
  def handle_parent_notification(:rebuild_filter_graph, _ctx, state) do
    {[], %{state | mixer: nil, layout_choice: nil}}
  end

  def handle_parent_notification({:rebuild_filter_graph, builder_state}, _ctx, state) do
    {[], %{state | mixer: nil, layout_choice: nil, builder_state: builder_state}}
  end

  defp primary_closed?(state) do
    case get_in(state, [:queue_by_pad, :primary]) do
      nil -> false
      queue -> FrameQueue.closed?(queue)
    end
  end

  defp primary_has_frame?(state) do
    case Map.get(state.queue_by_pad, :primary) do
      nil -> false
      queue -> FrameQueue.any?(queue)
    end
  end

  defp has_primary_spec?(state) do
    primary_role = Map.get(state.pad_roles, :primary)
    primary_role != nil and Map.has_key?(state.spec_by_role, primary_role)
  end

  defp all_have_frames?(pads, state) do
    Enum.all?(pads, fn pad ->
      queue = Map.get(state.queue_by_pad, pad)
      queue != nil and FrameQueue.any?(queue)
    end)
  end

  defp required_pads(layout_choice, state) do
    required_roles = required_roles(layout_choice, input_order(state))

    Enum.map(required_roles, fn role ->
      Enum.find(state.pad_roles, fn {_pad, r} -> r == role end) |> elem(0)
    end)
  end

  defp drain_all_extras(state) do
    state.queue_by_pad
    |> Enum.reject(fn {pad, _} -> pad == :primary end)
    |> Enum.reduce({[], state}, fn {pad, _}, {actions, state} ->
      drain_one_frame(pad, actions, state)
    end)
  end

  defp drain_non_required(state, required_pads) do
    required_set = MapSet.new(required_pads)
    state.queue_by_pad
    |> Enum.reject(fn {pad, _} -> MapSet.member?(required_set, pad) end)
    |> Enum.reduce({[], state}, fn {pad, _}, {actions, state} ->
      drain_one_frame(pad, actions, state)
    end)
  end

  # Returns {additional_actions, state}
  defp drain_one_frame(pad, actions, state) do
    queue = state.queue_by_pad[pad]
    if FrameQueue.any?(queue) do
      {_dropped, queue} = FrameQueue.pop!(queue)
      state = put_in(state, [:queue_by_pad, pad], queue)
      # MUST redemand to flush upstream Membrane buffers!
      {actions ++ [demand: {pad, 1}], state}
    else
      {actions, state}
    end
  end

  defp mix_or_drain(state) do
    cond do
      # Primary closed -> end stream
      primary_closed?(state) and not state.closed? ->
        {[end_of_stream: :output], %{state | closed?: true}}

      # Primary has no frames -> drain all extras (and redemand!)
      not primary_has_frame?(state) ->
        {drain_actions, state} = drain_all_extras(state)
        {drain_actions, state}

      # No primary spec yet -> wait for it to be popped
      not has_primary_spec?(state) ->
        {[], state}

      # Get layout, check if all required pads have frames
      true ->
        {layout_choice, state} = ensure_layout_choice(state)
        required_pads = required_pads(layout_choice, state)

        if all_have_frames?(required_pads, state) do
          {state, buffer} = mix(state, required_pads)
          {drain_actions, state} = drain_non_required(state, required_pads)
          {[buffer: {:output, [buffer]}, redemand: :output] ++ drain_actions, state}
        else
          {drain_actions, state} = drain_non_required(state, required_pads)
          {drain_actions, state}
        end
    end
  end

  defp mix(state, required_pads) do
    # Pop one item from each required pad, update spec_by_role if spec popped
    {popped_by_pad, state} =
      Enum.reduce(required_pads, {%{}, state}, fn pad, {acc, state} ->
        {popped, queue} = FrameQueue.pop!(state.queue_by_pad[pad])
        state = put_in(state, [:queue_by_pad, pad], queue)

        # Update spec_by_role when spec changes (popped includes spec_changed? flag)
        state =
          if popped.spec_changed? do
            role = pad_role!(state, pad)
            put_in(state, [:spec_by_role, role], popped.spec)
          else
            state
          end

        {Map.put(acc, pad, popped), state}
      end)

    # Check if mixer needs rebuild
    specs_changed? = Enum.any?(popped_by_pad, fn {_, p} -> p.spec_changed? end)

    # Build specs and frames maps
    frames_by_role = Map.new(popped_by_pad, fn {pad, p} ->
      {pad_role!(state, pad), p.frame}
    end)

    specs_by_role = Map.new(popped_by_pad, fn {pad, p} ->
      {pad_role!(state, pad), p.spec}
    end)

    primary_role = pad_role!(state, :primary)
    output_spec = Map.fetch!(specs_by_role, primary_role)

    # Rebuild mixer if needed
    mixer =
      if specs_changed? or state.mixer == nil do
        case state.layout_choice do
          {:layout, layout} ->
            {:ok, m} = VideoMixer.init(layout, specs_by_role, output_spec)
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

    case VideoMixer.mix(mixer, Map.to_list(frames_by_role)) do
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

  defp ensure_layout_choice(state) do
    if state.layout_choice != nil do
      {state.layout_choice, state}
    else
      primary_role = pad_role!(state, :primary)
      output_spec = Map.fetch!(state.spec_by_role, primary_role)
      layout_choice = state.layout_builder.(output_spec, state.spec_by_role, state.builder_state)
      {layout_choice, %{state | layout_choice: layout_choice}}
    end
  end

  defp required_roles({:layout, layout}, _input_order), do: layout_roles(layout)
  defp required_roles({:raw, _filter_graph}, input_order), do: input_order

  defp required_roles(other, _input_order),
    do: raise("invalid layout_builder result: #{inspect(other)}")

  defp layout_roles(:single_fit), do: [:primary]
  defp layout_roles(:hstack), do: [:left, :right]
  defp layout_roles(:vstack), do: [:top, :bottom]
  defp layout_roles(:xstack), do: [:top_left, :top_right, :bottom_left, :bottom_right]
  defp layout_roles(:primary_sidebar), do: [:primary, :sidebar]

  defp layout_roles(other),
    do: raise("invalid layout_builder result: #{inspect(other)}")
end
