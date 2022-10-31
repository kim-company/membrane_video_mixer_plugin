defmodule Membrane.VideoMixer.MasterMixer do
  @moduledoc """
  Provides a Membrane.Filter that produces a video output of the same size and
  pixel properties of its master video input, mixed with other video sources
  according to the provided filtering.
  """

  use Membrane.Filter

  alias VideoMixer
  alias VideoMixer.Frame
  alias VideoMixer.FrameSpec
  alias VideoMixer.FrameQueue

  require Logger

  @type filter_graph_builder_t ::
          (output_spec :: FrameSpec.t(), inputs :: [FrameSpec.t()], builder_state :: any ->
             VideoMixer.filter_graph_t())

  def_options filter_graph_builder: [
                spec: filter_graph_builder_t,
                description: """
                Provides a filter graph specification given the input and output frame specifications.
                """
              ],
              builder_state: [
                spec: any(),
                default: nil,
                description: """
                Initial state for the filter graph builder.
                """
              ]

  def_input_pad :master,
    mode: :pull,
    availability: :always,
    demand_unit: :buffers,
    caps: Membrane.RawVideo

  def_input_pad :extra,
    mode: :pull,
    availability: :on_request,
    demand_unit: :buffers,
    caps: Membrane.RawVideo

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    demand_unit: :buffers,
    caps: Membrane.RawVideo

  @impl true
  def handle_init(opts) do
    state = %{
      builder: opts.filter_graph_builder,
      builder_state: opts.builder_state,
      mixer: nil,
      framerate: nil,
      next_queue_index: 0,
      queue_by_pad: %{}
    }

    state = init_frame_queue(state, :master)

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    actions =
      state.queue_by_pad
      |> Map.keys()
      |> Enum.map(fn pad -> {:demand, {pad, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_pad_added(pad, ctx, state) do
    actions =
      if ctx.playback_state == :playing,
        do: [demand: {pad, 1}],
        else: []

    {{:ok, actions}, init_frame_queue(state, pad)}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    state = close_frame_queue(state, pad)
    mix_if_ready(state)
  end

  @impl true
  def handle_end_of_stream(pad, _ctx, state) do
    state = close_frame_queue(state, pad)
    mix_if_ready(state)
  end

  @impl true
  def handle_caps(_pad, %Membrane.RawVideo{framerate: nil}, _ctx, state) do
    {{:error, "mixer inputs must provide a framerate"}, state}
  end

  def handle_caps(_pad, %Membrane.RawVideo{framerate: {0, 1}}, _ctx, state) do
    {{:error, "mixer inputs must provide a stable framerate"}, state}
  end

  def handle_caps(
        _pad,
        %Membrane.RawVideo{framerate: framerate},
        _ctx,
        state = %{framerate: target_framerate}
      )
      when framerate != target_framerate and target_framerate != nil do
    {{:error,
      "all mixer inputs must agree on framerate. Have #{inspect(framerate)}, want #{inspect(target_framerate)}"},
     state}
  end

  def handle_caps(pad, caps = %Membrane.RawVideo{framerate: framerate}, _ctx, state) do
    frame_spec = build_frame_spec(pad, caps)

    state =
      state
      |> put_in([:framerate], framerate)
      |> update_in([:queue_by_pad, pad], fn queue ->
        FrameQueue.push(queue, frame_spec)
      end)

    if pad == :master do
      {{:ok, [forward: caps]}, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _context, state) do
    actions =
      state.queue_by_pad
      |> Enum.filter(fn {_pad, queue} ->
        FrameQueue.ready?(queue)
      end)
      |> Enum.reject(fn {_pad, queue} ->
        FrameQueue.any?(queue) or FrameQueue.closed?(queue)
      end)
      |> Enum.map(fn {pad, _queue} -> {:demand, {pad, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_process(pad, buffer, _ctx, state) do
    if master_closed?(state) do
      {:ok, state}
    else
      frame = %Frame{
        pts: buffer.pts,
        data: buffer.payload,
        size: byte_size(buffer.payload)
      }

      state
      |> update_in([:queue_by_pad, pad], fn queue -> FrameQueue.push(queue, frame) end)
      |> mix_if_ready()
    end
  end

  @impl true
  def handle_other({:rebuild_filter_graph, builder_state}, _ctx, state) do
    {:ok, %{state | mixer: nil, builder_state: builder_state}}
  end

  defp master_closed?(state) do
    state
    |> get_in([:queue_by_pad, :master])
    |> FrameQueue.closed?()
  end

  defp mix_if_ready(state) do
    # Handle closed queues first. If the master one is done, that's it.
    if master_closed?(state) do
      {{:ok, [end_of_stream: :output]}, state}
    else
      # delete all inputs that are now closed.
      prev_queues_count = map_size(state.queue_by_pad)

      state =
        update_in(state, [:queue_by_pad], fn queue_by_pad ->
          queue_by_pad
          |> Enum.filter(fn {_pad, queue} -> FrameQueue.closed?(queue) end)
          |> Enum.reduce(queue_by_pad, fn {pad, queue}, acc ->
            Logger.debug("Deleting closed queue: #{inspect(queue)}")
            Map.delete(acc, pad)
          end)
        end)

      cur_queues_count = map_size(state.queue_by_pad)
      specs_removed? = prev_queues_count != cur_queues_count
      state = if specs_removed?, do: %{state | mixer: nil}, else: state

      # consider the case when a pad is removed and it was the one not ready.
      # The other pads build a buffer and here we would consume just one.
      ready_frames =
        state.queue_by_pad
        |> Enum.filter(fn {_pad, queue} -> FrameQueue.ready?(queue) end)
        |> Enum.map(fn {_pad, queue} -> FrameQueue.size(queue) end)
        |> Enum.min()

      if ready_frames > 0 do
        {state, buffers} = mix_n(state, ready_frames, [])
        {{:ok, [buffer: {:output, buffers}, redemand: :output]}, state}
      else
        # wait for the next frame
        {:ok, state}
      end
    end
  end

  defp mix_n(state, 0, acc), do: {state, Enum.reverse(acc)}

  defp mix_n(state, n, acc) do
    {state, buffer} = mix(state)
    mix_n(state, n - 1, [buffer | acc])
  end

  defp mix(state = %{builder: builder, mixer: mixer}) do
    {frames_with_spec, state} =
      state.queue_by_pad
      |> Enum.filter(fn {_pad, queue} -> FrameQueue.ready?(queue) end)
      |> Enum.map_reduce(state, fn {pad, queue}, state ->
        {value, queue} = FrameQueue.pop!(queue)
        {value, put_in(state, [:queue_by_pad, pad], queue)}
      end)

    frames_with_spec =
      Enum.sort(frames_with_spec, fn %{index: left}, %{index: right} -> left < right end)

    specs_changed? =
      frames_with_spec
      |> Enum.filter(fn %{spec_changed?: x} -> x end)
      |> Enum.any?()

    mixer =
      if specs_changed? or mixer == nil do
        specs = Enum.map(frames_with_spec, fn %{spec: x} -> x end)
        [master_spec | _] = specs
        filter = builder.(master_spec, specs, state.builder_state)

        {:ok, mixer} = VideoMixer.init(filter, specs, master_spec)
        mixer
      else
        mixer
      end

    frames = Enum.map(frames_with_spec, fn %{frame: x} -> x end)
    [master_frame | _] = frames
    {:ok, raw_frame} = VideoMixer.mix(mixer, frames)

    buffer = %Membrane.Buffer{
      payload: raw_frame,
      pts: master_frame.pts
    }

    {%{state | mixer: mixer}, buffer}
  end

  defp init_frame_queue(state = %{next_queue_index: index}, pad) do
    state
    |> put_in([:queue_by_pad, pad], FrameQueue.new(index))
    |> put_in([:next_queue_index], index + 1)
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

  defp build_frame_spec(pad, caps) do
    %Membrane.RawVideo{width: width, height: height, pixel_format: format} = caps
    {:ok, size} = Membrane.RawVideo.frame_size(format, width, height)

    id =
      case pad do
        {Membrane.Pad, :extra, id} -> id
        :master -> :master
      end

    %FrameSpec{
      reference: id,
      width: width,
      height: height,
      pixel_format: format,
      accepted_frame_size: size
    }
  end
end
