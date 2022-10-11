defmodule RawVideo.FrameSpec do
  @type t :: %__MODULE__{
          reference: any(),
          width: pos_integer(),
          height: pos_integer(),
          pixel_format: atom(),
          expected_frame_size: integer()
        }
  defstruct [:reference, :width, :height, :pixel_format, :expected_frame_size]

  @doc "Returns true if `frame` is compatible with the provided specification."
  @spec compatible?(t(), RawVideo.Frame.t()) :: boolean()
  def compatible?(%__MODULE__{expected_frame_size: expected}, %RawVideo.Frame{size: actual}) do
    expected == actual
  end
end
