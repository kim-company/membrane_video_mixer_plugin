defmodule RawVideo.FrameSpec do
  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer(), pixel_format: atom(), index: pos_integer()}
  defstruct [:width, :height, :pixel_format, :index]

  @doc "Returns true if `frame` is compatible with the provided specification."
  @spec is_compatible?(t(), RawVideo.Frame.t()) :: boolean()
  def is_compatible?(_spec, _frame) do
    raise "is_compatible?/2 is not implemented"
  end

  def compare(%__MODULE__{index: left}, %__MODULE__{index: right}) do
    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end
end
