defmodule RawVideo.FrameSpec do
  @spec t :: %__MODULE__{width: pos_integer(), height: pos_integer(), pixel_format: atom()}
  defstruct [:width, :height, :pixel_format]

  @spec is_compatible?(t(), binary()) :: boolean()
  @doc "Returns true if `frame` is compatible with the provided specification."
  def is_compatible?(spec, frame) do
    raise "is_compatible?/2 is not implemented"
  end
end
