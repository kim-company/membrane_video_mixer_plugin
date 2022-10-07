defmodule Membrane.VideoMixer do
  @moduledoc """
  This element performs video mixing.
  """

  use Membrane.Filter
  use Bunch

  require Membrane.Logger

  alias Membrane.{Buffer, RawVideo, Time}
  alias Membrane.VideoMixer.{Mixer, FrameQueue}

  def_options output_caps: [
                type: :struct,
                spec: RawVideo.t(),
                description: """
                Defines the caps of the output video.
                """,
                default: nil
              ],
              filters: [
                type: :struct,
                spec: (width :: integer, height :: integer, inputs :: integer -> String.t()),
                description: """
                Defines the filter building function.
                """,
                default: nil
              ]

  def_input_pad :input,
    mode: :pull,
    availability: :on_request,
    demand_unit: :buffers,
    caps: RawVideo

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    demand_unit: :buffers,
    caps: RawVideo

  @impl true
  def handle_init(%__MODULE__{} = options) do
    state =
      options
      |> Map.from_struct()
      |> Map.put(:pads, %{})
      |> Map.put(:mixer_state, nil)
      |> Map.put(:framerate, nil)
      |> Map.put(:timer, nil)
      |> Map.put(:frame_interval, nil)
      |> Map.update!(:filters, fn
        nil ->
          # default filters
          fn
            width, height, 1 ->
              "[0:v]scale=#{width}:#{height}:force_original_aspect_ratio=decrease,setsar=1/1,pad=#{width}:#{height}:(ow-iw)/2:(oh-ih)/2"

            width, height, 2 ->
              "[0:v]scale=#{width}/3*2:#{height}:force_original_aspect_ratio=decrease,pad=#{width}/3*2+1:#{height}:-1:-1,setsar=1[l];[1:v]scale=-1:#{height}/3*2,crop=#{width}/3:ih:iw/3:0,pad=#{width}/3:#{height}:-1:-1,setsar=1[r];[l][r]hstack"

            _, _, n ->
              raise("No matching filter found for #{n} input(s)")
          end

        other ->
          other
      end)
      |> Map.put(:mixer_queue, %{caps_state: :ok, queue: %{}})

    {:ok, state}
  end

  @impl true
  def handle_pad_added(pad, _context, state) do
    index = length(Map.keys(state.pads))

    state =
      state
      |> Bunch.Access.put_in([:pads, pad], %{
        queue: FrameQueue.new(),
        stream_ended: false,
        idx: index
      })
      |> Bunch.Access.put_in([:mixer_queue, :queue, index], %{
        ref: pad,
        payload: nil,
        expected_size: nil
      })

    {:ok, state}
  end

  @impl true
  def handle_pad_removed(pad, _context, state) do
    {:ok, remove_pad(state, pad)}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{output_caps: %RawVideo{} = caps} = state) do
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_context, state) do
    {:ok, %{state | mixer_state: nil}}
  end

  @impl true
  def handle_demand(:output, buffer_count, :buffers, _context, state = %{pads: pads}) do
    pads
    |> Enum.map(fn {pad, %{queue: queue}} ->
      queue
      |> FrameQueue.frames_length()
      |> then(&{:demand, {pad, max(0, buffer_count - &1)}})
    end)
    |> then(fn demands -> {{:ok, demands}, state} end)
  end

  @impl true
  def handle_start_of_stream(_pad, _context, state) do
    fill_and_mix(state)
  end

  @impl true
  def handle_end_of_stream(pad, _context, state) do
    index = Bunch.Access.get_in(state, [:pads, pad, :idx])

    Membrane.Logger.debug("handle_end_of_stream: Pad nr. #{index} stream ended")

    # pad will be removed as soon as its frame is empty
    state = Bunch.Access.update_in(state, [:pads, pad], &%{&1 | stream_ended: true})

    if all_streams_ended?(state) do
      flush(state)
    else
      fill_and_mix(state)
    end
  end

  @impl true
  def handle_process(pad_ref, %Buffer{payload: payload}, _context, state) do
    # enqueue recieved buffer and mix if enogh buffers are in queue
    state =
      Bunch.Access.update_in(state, [:pads, pad_ref], fn pad = %{queue: queue} ->
        %{pad | queue: FrameQueue.put_frame(queue, payload)}
      end)

    fill_and_mix(state)
  end

  @impl true
  def handle_caps(pad_ref, %RawVideo{framerate: {0, 1}}, _context, _state) do
    raise RuntimeError, "received invalid caps on pad #{inspect(pad_ref)}. caps with dynamic framerate are not allowed."
  end

  def handle_caps(pad_ref, caps, context, %{framerate: nil} = state) do
    case caps.framerate do
      {0, 1} ->
        raise RuntimeError, "received invalid caps on pad #{inspect(pad_ref)}. caps with dynamic framerate are not allowed."

      {framerate, 1} ->
        state =
          state
          |> Map.put(:framerate, {framerate, 1})
          |> Map.put(:frame_interval, Time.second() / framerate)
          |> Map.put(:timer, Time.seconds(0))

        handle_caps(pad_ref, caps, context, state)

      framerate ->
        raise RuntimeError, "received invalid caps on pad #{inspect(pad_ref)}. only round framerates are allowed. received: #{inspect framerate}."
    end
  end

  def handle_caps(pad_ref, %RawVideo{framerate: framerate} = caps, _context, %{framerate: framerate} = state) do
    state =
      Bunch.Access.update_in(state, [:pads, pad_ref], fn pad = %{queue: queue} ->
        %{pad | queue: FrameQueue.put_caps(queue, caps)}
      end)

    {:ok, state}
  end

  def handle_caps(pad_ref, %RawVideo{framerate: f1}, _context, %{framerate: f2}) do
    raise RuntimeError, "received invalid caps on pad #{inspect(pad_ref)}. received: #{inspect f1}. expected: #{inspect f2}. The framerate must match."
  end

  defp initialize_mixer_state(state = %{output_caps: caps, filters: filters}) do
    input_caps = get_ordered_caps(state)

    mixer_state = Mixer.init(input_caps, caps, filters)

    state
    |> Map.put(:mixer_state, mixer_state)
    |> put_expected_size(input_caps)
  end

  defp put_expected_size(state = %{mixer_queue: %{queue: queue}}, input_caps) do
    queue =
      input_caps
      |> Enum.with_index()
      |> Enum.reduce(queue, fn {caps, i}, queue ->
        {:ok, size} = RawVideo.frame_size(caps)
        Bunch.Access.put_in(queue, [i, :expected_size], size)
      end)

    Bunch.Access.put_in(state, [:mixer_queue, :queue], queue)
  end

  defp fill_and_mix(state) do
    {state, fill_action} = fill_inputs(state)

    case fill_action do
      :wait -> {{:ok, [redemand: :output]}, state}
      :stop -> {{:ok, [end_of_stream: :output]}, state}
      :ok -> mix_inputs(state)
    end
  end

  defp fill_inputs(state) do
    Enum.reduce(state.mixer_queue.queue, {state, :ok}, fn
      {_idx, %{ref: ref, payload: nil}}, {state, state_action} ->
        {result, state} =
          Bunch.Access.get_and_update_in(state, [:pads, ref, :queue], &FrameQueue.get_frame(&1))

        case result do
          :empty ->
            if Bunch.Access.get_in(state.pads, [ref, :stream_ended]) do
              state = remove_pad(state, ref)

              if length(Map.keys(state.pads)) == 0 do
                {state, :stop}
              else
                {state, state_action}
              end
            else
              {state, :wait}
            end

          {:ok, payload} ->
            # get the new index if one of the pads was deleted
            idx = Bunch.Access.get_in(state, [:pads, ref, :idx])

            {Bunch.Access.put_in(state, [:mixer_queue, :queue, idx, :payload], payload),
             state_action}

          {:change, payload} ->
            # get the new index if one of the pads was deleted
            idx = Bunch.Access.get_in(state, [:pads, ref, :idx])

            state =
              state
              |> Bunch.Access.put_in([:mixer_queue, :queue, idx, :payload], payload)
              |> Bunch.Access.put_in([:mixer_queue, :caps_state], :restart)

            {state, state_action}
        end

      _, acc ->
        acc
    end)
  end

  defp mix_inputs(state = %{mixer_queue: %{caps_state: :restart}}) do
    state
    |> initialize_mixer_state()
    |> Bunch.Access.put_in([:mixer_queue, :caps_state], :ok)
    |> mix_inputs()
  end

  defp mix_inputs(state = %{mixer_queue: %{queue: queue}}) do
    {queue, payloads, action} =
      Enum.reduce(queue, {[], [], :ok}, fn {idx, item}, {queue, payloads, action} ->
        action =
          if byte_size(item.payload) == item.expected_size do
            action
          else
            Membrane.Logger.warn(
              "Input of size #{byte_size(item.payload)} was recieved while expected size is #{item.expected_size}\nInputs wil be discarded"
            )

            :drop
          end

        {[{idx, Map.put(item, :payload, nil)} | queue], [item.payload | payloads], action}
      end)

    state = Bunch.Access.put_in(state, [:mixer_queue, :queue], Map.new(queue))

    case action do
      :ok ->
        payload =
          payloads
          |> Enum.reverse()
          |> Mixer.mix(state.mixer_state)

        buffer = %Buffer{payload: payload, pts: state.timer}
        {{:ok, [buffer: {:output, buffer}]}, increment_timer(state)}

      :drop ->
        state
        |> increment_timer()
        |> fill_and_mix()
    end
  end

  defp get_ordered_caps(%{pads: pads}) do
    pads
    |> Enum.map(fn {_pad_ref, %{queue: queue, idx: index}} ->
      {index, FrameQueue.read_caps(queue)}
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp remove_pad(state = %{pads: pads, mixer_queue: %{queue: queue}}, pad_ref) do
    # removes a pad and rearranges the index of the remaining ones
    index = Bunch.Access.get_in(state, [:pads, pad_ref, :idx])

    pads =
      pads
      |> Enum.map(fn
        {pad_ref, pad = %{idx: idx}} when idx > index ->
          {pad_ref, %{pad | idx: idx - 1}}

        elem ->
          elem
      end)
      |> Map.new()

    queue =
      if index <= length(Map.keys(pads)) - 2 do
        index..(length(Map.keys(pads)) - 2)
        |> Enum.reduce(queue, fn n, queue ->
          Map.put(queue, n, queue[n + 1])
        end)
        |> Map.delete(length(Map.keys(pads)) - 1)
      else
        Map.delete(queue, length(Map.keys(pads)) - 1)
      end

    state
    |> Map.put(:pads, pads)
    |> Bunch.Access.delete_in([:pads, pad_ref])
    |> Bunch.Access.put_in([:mixer_queue, :queue], queue)
    |> Bunch.Access.put_in([:mixer_queue, :caps_state], :restart)
  end

  defp all_streams_ended?(%{pads: pads}) do
    Enum.all?(pads, fn {_, %{stream_ended: stream_ended}} ->
      stream_ended
    end)
  end

  defp flush(state, result \\ []) do
    # flush all frames that are in the queue
    {state, fill_action} = fill_inputs(state)

    case fill_action do
      :ok ->
        {{:ok, [buffer: {:output, buffer}]}, state} = mix_inputs(state)
        flush(state, [buffer | result])

      :stop ->
        end_flush(state, result)

      :wait ->
        raise("this is a bug")
    end
  end

  defp end_flush(state, []), do: {{:ok, [end_of_stream: :output]}, state}

  defp end_flush(state, buffers) do
    {{:ok, [buffer: {:output, Enum.reverse(buffers)}, end_of_stream: :output]}, state}
  end

  defp increment_timer(state = %{timer: timer, frame_interval: interval}) do
    %{state | timer: timer + interval}
  end
end
