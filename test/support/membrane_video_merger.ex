defmodule Membrane.VideoMerger do
  @moduledoc """
  Allows to simulate quality switches by concatenating different files.
  New caps are sent when an input has finished.
  """
  use Membrane.Filter
  use Bunch
  alias Membrane.{RawVideo, Pad}

  def_input_pad(:input,
    mode: :pull,
    availability: :on_request,
    demand_unit: :buffers,
    caps: RawVideo
  )

  def_output_pad(:output,
    mode: :pull,
    availability: :always,
    demand_unit: :buffers,
    caps: RawVideo
  )

  @impl true
  def handle_init(_) do
    {:ok, %{pads: [], caps: %{}}}
  end

  @impl true
  def handle_pad_added({_, :input, pad}, _context, state = %{pads: pads}) do
    {:ok, %{state | pads: pads ++ [pad]}}
  end

  def handle_pad_added(_, _, state) do
    {:ok, state}
  end

  @impl true
  def handle_caps({_, :input, pad}, caps, _, state) do
    state = Bunch.Access.put_in(state, [:caps, pad], caps)

    case length(Map.keys(state.caps)) do
      1 ->
        {{:ok, caps: {:output, caps}}, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_demand(:output, buffers, :buffers, _, state = %{pads: [active | _rest]}) do
    {{:ok, [{:demand, {Pad.ref(:input, active), buffers}}]}, state}
  end

  @impl true
  def handle_end_of_stream({_, :input, pad}, _ctx, state = %{pads: [pad | []]}) do
    {{:ok, [end_of_stream: :output]}, %{state | pads: []}}
  end

  def handle_end_of_stream({_, :input, pad}, _ctx, state = %{pads: [pad | pads]}) do
    new_caps = Map.get(state.caps, List.first(pads))
    {{:ok, [caps: {:output, new_caps}, redemand: :output]}, %{state | pads: pads}}
  end

  def handle_end_of_stream(_, _, _), do: raise("stream ended for wrong pad")

  @impl true
  def handle_process_list({_, :input, pad}, buffers, _, state = %{pads: [pad | _]}) do
    {{:ok, [buffer: {:output, buffers}]}, state}
  end

  def handle_process(_, _, _, _), do: raise("recieved process for wrong pad")
end
