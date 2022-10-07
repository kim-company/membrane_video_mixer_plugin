defmodule Membrane.VideoMixer.FrameQueue do
  @type t() :: {{metadata(), erl_queue()}, [{metadata(), erl_queue()}]}
  @type erl_queue() :: {[payload()], [payload()]}
  @type metadata() :: any()
  @type payload() :: any()

  @spec new() :: t()
  def new() do
    {{nil, :queue.new()}, []}
  end

  @doc "Put a frame at the end of the queue"
  @spec put_frame(t(), payload()) :: t()
  def put_frame({{caps, queue}, []}, frame) do
    {{caps, :queue.in(frame, queue)}, []}
  end

  def put_frame({front, [{caps, queue} | back]}, frame) do
    {front, [{caps, :queue.in(frame, queue)} | back]}
  end

  @doc "Create a new item with the selected caps"
  @spec put_caps(t(), metadata()) :: t()
  def put_caps({front, list}, caps) do
    {front, [{caps, :queue.new()} | list]}
  end

  @doc """
  Get a frame from the queue. If the first item is empty, switches the current caps to the next one in the queue.
  """
  @spec get_frame(t()) :: {{:ok | :change, payload()} | :empty, t()}
  def get_frame(queue = {{_, {[], []}}, []}), do: {:empty, queue}

  def get_frame(input = {{_caps, {[], []}}, back}) do
    [{caps, queue} | back] = Enum.reverse(back)

    case :queue.out(queue) do
      {{:value, frame}, queue} ->
        {{:change, frame}, {{caps, queue}, Enum.reverse(back)}}

      {:empty, _queue} ->
        {:empty, input}
    end
  end

  def get_frame({{caps, queue}, back}) do
    {{:value, frame}, queue} = :queue.out(queue)

    {{:ok, frame}, {{caps, queue}, back}}
  end

  @doc "Read the first caps in the queue"
  @spec read_caps(t()) :: metadata()
  def read_caps({{caps, _}, _}), do: caps

  @spec frames_length(t()) :: integer()
  def frames_length({{_caps, queue}, []}), do: :queue.len(queue)

  def frames_length({{_caps, queue}, [head | back]}) do
    :queue.len(queue) + frames_length({head, back})
  end

  @spec initialized?(t()) :: boolean()
  def initialized?({{nil, _}, _}), do: false
  def initialized?(_), do: true

  @spec empty?(t()) :: boolean()
  def empty?({{_caps, {[], []}}, []}), do: true
  def empty?({{_caps, {[], []}}, [head | tail]}), do: empty?({head, tail})
  def empty?(_), do: false
end
