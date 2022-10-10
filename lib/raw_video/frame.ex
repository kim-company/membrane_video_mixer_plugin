defmodule RawVideo.Frame do
  @type t :: %__MODULE__{data: binary(), pts: integer(), size: integer()}
  defstruct [:data, :pts, :size]
end
