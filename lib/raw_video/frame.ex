defmodule RawVideo.Frame do
  @type t :: %__MODULE__{data: binary(), index: pos_integer()}
  defstruct [:index, :data]

  def compare(%__MODULE__{index: left}, %__MODULE__{index: right}) do
    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  def size(%__MODULE__{data: data}), do: byte_size(data)
end
