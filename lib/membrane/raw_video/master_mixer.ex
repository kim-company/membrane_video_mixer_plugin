defmodule Membrane.RawVideo.MasterMixer do
  @moduledoc """
  Provides a Membrane.Filter that produces a video output of the same size and
  pixel properties of its master video input, mixed with other video sources
  according to the provided filtering.
  """

  use Membrane.Filter

  alias RawVideo.FrameSpec
  alias RawVideo.Mixer
  alias Membrane.RawVideo.FrameQueue

  require Logger

  @type filter_graph_builder_t ::
          (output_spec :: FrameSpec.t(), inputs :: [FrameSpec.t()] -> Mixer.filter_graph_t())

  def_options filter_graph_builder: [
                spec: filter_graph_builder_t,
                description: """
                Provides a filter graph specification given the input and output frame specifications.
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
  def handle_init(%__MODULE__{filter_graph_builder: builder}) do
    state = %{
      builder: builder,
      mixer: nil,
      framerate: nil,
      next_queue_index: 0,
      queue_by_pad: %{}
    }

    state = init_frame_queue(state, :master)

    {:ok, state}
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    {:ok, init_frame_queue(state, pad)}
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
  def handle_demand(:output, size, :buffers, ctx, state) do
    actions =
      ctx.pads
      |> Enum.map(fn {ref, _data} -> ref end)
      |> Enum.filter(fn ref -> Pad.name_by_ref(ref) != :output end)
      |> Enum.map(fn ref -> {:demand, {ref, size}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_process(pad, buffer, _ctx, state) do
    frame = %RawVideo.Frame{
      pts: buffer.pts,
      data: buffer.payload,
      size: byte_size(buffer.payload)
    }

    state
    |> update_in([:queue_by_pad, pad], fn queue -> FrameQueue.push(queue, frame) end)
    |> mix_if_ready()
  end

  @impl true
  def handle_other(:rebuild_filter_graph, _ctx, state) do
    {:ok, %{state | mixer: nil}}
  end

  defp mix_if_ready(state) do
    # Handle closed queues first. If the master one is done, that's it.
    master_closed? =
      state
      |> get_in([:queue_by_pad, :master])
      |> FrameQueue.closed?()

    if master_closed? do
      {{:ok, [end_of_stream: :output]}, state}
    else
      # delete all inputs that are now closed.
      state =
        update_in(state, [:queue_by_pad], fn queue_by_pad ->
          queue_by_pad
          |> Enum.filter(fn {_pad, queue} -> FrameQueue.closed?(queue) end)
          |> Enum.reduce(queue_by_pad, fn {pad, queue}, acc ->
            Logger.warn("Deleting closed queue: #{inspect(queue)}")
            Map.delete(acc, pad)
          end)
        end)

      # redemand raw videos on pads that are not ready yet.

      pads_not_ready =
        state.queue_by_pad
        |> Enum.filter(fn {_pad, queue} -> !FrameQueue.ready?(queue) end)
        |> Enum.map(fn {pad, _queue} -> pad end)

      ready? = length(pads_not_ready) == 0

      if ready? do
        mix(state)
      else
        actions = Enum.map(pads_not_ready, fn pad -> {:redemand, :output} end)
        {{:ok, actions}, state}
      end
    end
  end

  defp mix(state = %{builder: builder, mixer: mixer}) do
    {values, state} =
      Enum.map_reduce(state.queue_by_pad, state, fn {pad, queue}, state ->
        {value, queue} = FrameQueue.pop!(queue)
        {value, put_in(state, [:queue_by_pad, pad], queue)}
      end)

    values = Enum.sort(values, fn %{index: left}, %{index: right} -> left < right end)

    specs_changed? =
      values
      |> Enum.filter(fn %{spec_changed?: x} -> x end)
      |> Enum.any?()

    mixer =
      if specs_changed? or mixer == nil do
        specs = Enum.map(values, fn %{spec: x} -> x end)
        [master_spec | _] = specs
        filter = builder.(master_spec, specs)

        # Boom?
        {:ok, mixer} = Mixer.init(filter, specs, master_spec)
        mixer
      else
        mixer
      end

    frames = Enum.map(values, fn %{frame: x} -> x end)
    [master_frame | _] = frames
    {:ok, raw_frame} = Mixer.mix(mixer, frames)

    buffer = %Membrane.Buffer{
      payload: raw_frame,
      pts: master_frame.pts
    }

    {{:ok, [buffer: {:output, buffer}]}, %{state | mixer: mixer}}
  end

  defp init_frame_queue(state = %{next_queue_index: index}, pad) do
    state
    |> put_in([:queue_by_pad, pad], FrameQueue.new(index))
    |> put_in([:next_queue_index], index + 1)
  end

  defp close_frame_queue(state, pad) do
    update_in(state, [:queue_by_pad, pad], fn queue ->
      FrameQueue.push(queue, :end_of_stream)
    end)
  end

  defp build_frame_spec(pad, caps) do
    %Membrane.RawVideo{width: width, height: height, pixel_format: format} = caps
    {:ok, size} = Membrane.RawVideo.frame_size(format, width, height)

    id =
      case pad do
        {Membrane.Pad, :extra, id} -> id
        :master -> :master
      end

    %RawVideo.FrameSpec{
      reference: id,
      width: width,
      height: height,
      pixel_format: format,
      expected_frame_size: size
    }
  end
end
