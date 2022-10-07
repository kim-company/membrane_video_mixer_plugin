defmodule RawVideo.Mixer do
  alias RawVideo.Mixer.Native
  alias RawVideo.FrameSpec
  alias RawVideo.Frame

  # Libavfilter definition in textual format, to be parsed by
  # avfilter_graph_parse().
  #
  # `[0:v]scale=w=iw/2[left],[1:v]scale=w=iw/2[right],[left][right]framepack=sbs`
  # Taken from https://libav.org/documentation/libavfilter.html#toc-framepack,
  # this filter graph example packs two different video streams into a
  # stereoscopic video, setting proper metadata on supported codecs. The
  # `[0:v]` portion, generalized here as `[index:v]`, addresses the `index`
  # frame presented to the filtering engine as an array of frames. In the
  # spec_mapping's frames, ensure that each `index` set here has a
  # corresponding spec.
  @type filter_graph_t :: String.t()

  # Within the filter_graph, frames are referred to by index. Each frame
  # contains an index field that specifies the mapping.
  @type spec_mapping_t :: [FrameSpec.t()]

  @type t :: %__MODULE__{mapping: spec_mapping_t(), ref: reference()}
  defstruct [:mapping, :ref]

  @doc """
  Initializes the mixer. `mapping` frames must be numbered from 0 to
  length(mapping)-1. Ordering is not important.
  """
  @spec init(filter_graph_t(), spec_mapping_t(), FrameSpec.t()) :: {:ok, t()} | {:error, any}
  def init(filter, mapping, output_frame_spec) do
    sorted_mapping = Enum.sort(mapping, FrameSpec)

    {widths, heights, formats, indexes} =
      sorted_mapping
      |> Enum.map(fn %FrameSpec{width: w, height: h, pixel_format: f, index: i} -> [w, h, f, i] end)
      |> Enum.zip()

    expected_indexes = Range.new(0, length(mapping)-1) |> Enum.into([])
    if indexes != expected_indexes do
      raise ArgumentError, "Invalid frame spec mapping: indexing expected range is #{inspect expected_indexes}, got #{inspect indexes}"
    end

    %FrameSpec{width: out_width, height: out_height, pixel_format: out_format} = output_frame_spec

    case Native.init(widths, heights, formats, filter, out_width, out_height, out_format) do
      {:ok, ref} ->
        %RawVideo.Mixer{ref: ref, mapping: sorted_mapping}

      {:error, reason} ->
        {:error, reason}
    end
  end
  
  
  @spec mix(t(), [Frame.t()]) :: {:ok, binary()} | {:error, any()}
  def mix(%__MODULE__{ref: ref, mapping: mapping}, frames) do
    sorted_frames = Enum.sort(frames, Frame)
    with :ok <- assert_spec_compatibility(mapping, sorted_frames) do
      Native.mix(sorted_frames, ref)
    end
  end

  defp assert_spec_compatibility([], []), do: :ok
  defp assert_spec_compatibility(specs, frames) when length(specs) != length(frames) do
    {:error, "mixer needs ##{length(specs)} frames for mixing, got ##{length(frames)}"}
  end
  defp assert_spec_compatibility([spec | spec_rest], [frame | frame_rest]) do
    cond do
      spec.index != frame.index ->
        {:error, "frame with index #{frame.index} is paired with spec with index #{spec.index}"}
      !FrameSpec.is_compatible?(spec, frame) ->
        {:error, "frame with index #{frame.index} and size #{Frame.size(frame)} is incompatible with spec #{inspect spec}"}
      true -> assert_spec_compatibility(spec_rest, frame_rest)
    end
  end
end
