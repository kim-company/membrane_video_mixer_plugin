defmodule Membrane.VideoMixer.Mixer do
  alias __MODULE__.Native
  require Membrane.Logger

  @type caps :: %{width: integer(), height: integer(), pixel_format: atom()}

  @spec init([caps()], caps(), fun()) :: reference()
  def init(
        inputs,
        output = %{width: out_width, height: out_height, pixel_format: out_format},
        filter_fn
      ) do
    [width, height, format] =
      inputs
      |> Enum.reduce([[], [], []], fn
        %{width: width, height: height, pixel_format: format}, [w, h, f] ->
          [[width | w], [height | h], [format | f]]
      end)
      |> Enum.map(&Enum.reverse/1)

    Membrane.Logger.info(
      "Initializing mixer with following config:\ninputs: #{inspect(inputs)}\noutput: #{inspect(output)}"
    )

    filters = filter_fn.(out_width, out_height, length(inputs))

    case Native.init(
           width,
           height,
           format,
           filters,
           out_width,
           out_height,
           out_format
         ) do
      {:ok, ref} ->
        ref

      {:error, reason} ->
        raise inspect(reason)
    end
  end

  @spec mix([binary()], reference()) :: binary()
  def mix(buffers, state) do
    Membrane.Logger.debug("Start mixing #{length(buffers)} payload(s)")

    case Native.mix(buffers, state) do
      {:ok, frame} ->
        Membrane.Logger.debug("Produced frame of size: #{byte_size(frame)}")
        frame

      {:error, reason} ->
        raise inspect(reason)
    end
  end
end
