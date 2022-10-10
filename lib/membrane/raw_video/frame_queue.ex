defmodule Membrane.RawVideo.FrameQueue do
  defmodule QexWithCount do
    defstruct queue: Qex.new(), count: 0

    def new(), do: %__MODULE__{}

    def push(state = %__MODULE__{queue: queue, count: count}, item) do
      %__MODULE__{state | queue: Qex.push(queue, item), count: count + 1}
    end

    def pop!(state = %__MODULE__{queue: queue, count: count}) do
      {item, queue} = Qex.pop!(queue)
      {item, %__MODULE__{state | queue: queue, count: count - 1}}
    end

    def empty?(%__MODULE__{count: 0}), do: true
    def empty?(_state), do: false
  end

  defstruct [:index, :current_frame_spec, :stream_finished?, :spec_changed?, :ready, :pending]

  def new(index) do
    %__MODULE__{
      index: index,
      current_frame_spec: nil,
      spec_changed?: false,
      stream_finished?: false,
      ready: QexWithCount.new(),
      pending: QexWithCount.new()
    }
  end

  def push(state = %__MODULE__{pending: pending, ready: ready}, spec = %RawVideo.FrameSpec{}) do
    state = %{state | spec_changed?: true, current_frame_spec: spec}

    if QexWithCount.empty?(pending) do
      state
    else
      frames = Enum.into(pending.queue, [])

      pending_accepted? =
        frames
        |> Enum.map(fn x -> RawVideo.FrameSpec.compatible?(spec, x) end)
        |> Enum.all?()

      if !pending_accepted? do
        raise ArgumentError,
              "frame queue received spec #{inspect(spec)} which is not compatible with the pending frame queue (size #{pending.count})"
      end

      Enum.reduce(frames, state, fn x, state -> push(state, x) end)
    end
  end

  def push(state = %__MODULE__{current_frame_spec: spec}, frame = %RawVideo.Frame{}) do
    if spec == nil or !RawVideo.FrameSpec.compatible?(spec, frame) do
      %{state | pending: QexWithCount.push(state.pending, frame)}
    else
      ready =
        QexWithCount.push(state.ready, %{
          index: state.index,
          frame: frame,
          spec: spec,
          spec_changed?: state.spec_changed?
        })

      %{state | ready: ready, spec_changed?: false}
    end
  end

  def ready?(%__MODULE__{ready: %QexWithCount{count: count}}), do: count > 0

  def closed?(%__MODULE__{stream_finished?: done, ready: ready}) do
    QexWithCount.empty?(ready) and done
  end

  def pop!(state = %__MODULE__{ready: ready}) do
    {value, ready} = QexWithCount.pop!(ready)
    {value, %{state | ready: ready}}
  end
end
