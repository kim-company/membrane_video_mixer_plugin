defmodule Membrane.RawVideo.MasterMixer do
  @moduledoc """
  Provides a Membrane.Filter that produces a video output of the same size
  and pixel properties of its master video input, mixed with other video
  sources according to the provided filtering.
  """

  use Membrane.Filter

  alias RawVideo.FrameSpec
  alias RawVideo.Mixer
  alias Membrane.RawVideo.FrameQueue

  @type filter_graph_builder_t :: (output_spec :: FrameSpec.t(), inputs :: [FrameSpec.t()] -> Mixer.filter_graph_t)

  def_options filter_graph_builder: [
    spec: filter_graph_builder_t,
    description: """
    Provides a filter graph specification given the input and output frame specifications.
    """,
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
    state = %{builder: builder, framerate: nil, output_frame_spec: nil, queue_by_pad: %{}}
    state = init_pad(:master, state)
    {:ok, state}
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    {:ok, init_pad(pad, state)}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    {:ok, terminate_pad(pad, state)}
  end

  @impl true
  def handle_end_of_stream(pad, _ctx, state) do
    {:ok, terminate_pad(pad, state)}
  end

  @impl true
  def handle_caps({Membrane.Pad, :extra, 0}, _caps, _ctx, state) do
    {{:error, "mixer extra input index must be > 0"}, state}
  end

  def handle_caps(pad, caps = %Membrane.RawVideo{framerate: framerate}, _ctx, state) do
    cond do
      framerate == nil or framerate == {0, 1} ->
        {{:error, "mixer inputs must provide a stable framerate"}, state} 

      state.framerate != nil and state.framerate != framerate ->
        {{:error, "all mixer inputs must agree on framerate. Have #{inspect framerate}, want #{inspect state.framerate}"}, state}

      true ->
        {state, actions, frame_spec} = if Pad.name_by_ref(pad) == :master do
          frame_spec = build_frame_spec(caps, 0)
          {put_in(state, [:output_frame_spec], frame_spec), [forward: caps], frame_spec}
        else
          {Membrane.Pad, :extra, index} = pad
          frame_spec = build_frame_spec(caps, index)
          {state, [], frame_spec}
        end

        state =
          state
          |> put_in([:framerate], framerate)
          |> get_and_update_in([:queue_by_pad, pad], fn queue ->
            # We're putting FrameSpecs, not caps :D
            FrameQueue.put_caps(queue, frame_spec)
          end)

        {{:ok, actions}, state}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, ctx, state) do
    actions = build_demand_actions(ctx.pads, size)
    {{:ok, actions}, state}
  end

  defp init_pad(pad, state) do
    put_in(state, [:queue_by_pad, pad], FrameQueue.new())
  end

  defp terminate_pad(pad, state) do
    state = get_and_update_in(state, [:queue_by_pad, pad], fn queue ->
        FrameQueue.put_frame(queue, :end_of_stream)
    end)
    {:ok, state}
  end

  defp build_frame_spec(%Membrane.RawVideo{width: width, height: height, pixel_format: format, aligned: true}, index) do
    %RawVideo.FrameSpec{width: width, height: height, pixel_format: format, index: index}
  end

  defp build_demand_actions(pads, size) do
    pads
    |> Enum.map(fn {ref, _data} -> ref end)
    |> Enum.filter(fn ref -> Pad.name_by_ref(ref) != :output end)
    |> Enum.map(fn ref -> {:demand, {ref, size}} end)
  end
end
