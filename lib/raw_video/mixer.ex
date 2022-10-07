defmodule RawVideo.Mixer do
  alias RawVideo.Mixer.Native
  alias RawVideo.FrameSpec

  @doc """
  Libavfilter definition in textual format, to be parsed by
  avfilter_graph_parse().

  `[0:v]scale=w=iw/2[left],[1:v]scale=w=iw/2[right],[left][right]framepack=sbs`
  Taken from https://libav.org/documentation/libavfilter.html#toc-framepack,
  this filter graph example packs two different video streams into a
  stereoscopic video, setting proper metadata on supported codecs. The
  `[0:v]` portion, generalized here as `[index:v]`, addresses the `index`
  frame presented to the filtering engine as an array of frames. In the
  spec_mapping ensure that each `index` set here has a corresponding spec.
  """
  @type filter_graph_t :: String.t()

  @doc """
  Within the filter_graph, frames are referred to by index. This mapping
  specifies the frame spec of each input graph.
  """
  @type spec_mapping_t :: map(required(index :: pos_integer()) => FrameSpec.t())

  @type t :: %__MODULE__{mapping: spec_mapping_t(), ref: reference()}
  defstruct [:mapping, :ref]

  @spec init(filter_graph_t(), spec_mapping_t(), FrameSpec.t()) :: {:ok, t() | {:error, any}
  def init(filter, mapping, output_frame_spec) do
    {widths, heights, formats} =
      mapping
      |> Enum.into([])
      |> Enum.sort(fn {left, _}, {right, _} -> left < right end)
      |> Enum.map(fn {_index, value} -> value end)
      |> Enum.map(fn %FrameSpec{width: w, height: h, pixel_format: f} -> [w, h, f] end)
      |> Enum.zip()

    %FrameSpec{width: out_width, height: out_height, pixel_format: out_format} = output_frame_spec

    case Native.init(widths, heights, formats, filter, out_width, out_height, out_format) do
      {:ok, ref} ->
        %RawVideo.Mixer{ref: ref, mapping: mapping}

      {:error, reason} ->
        {:error, reason}
    end
  end
  
  
  @spec mix(t(), [{binary(), pos_integer()}]) :: {:ok, binary()} | {:error, any()}
  def mix(%__MODULE__{ref: ref, mapping: mapping}, frames_with_index) do
    sorted_frames =
      frames_with_index
      |> Enum.sort(fn {_, left}, {_, right} -> left < right end)
      |> Enum.map(fn {frame, _index} -> frame end)

    with :ok <- assert_spec_compatibility(mapping, frames_with_index) do
      Native.mix(sorted_frames, ref)
    end
  end

  defp assert_spec_compatibility(mapping, frames_with_index) do
    maybe_error =
      frames_with_index
      |> Enum.map(fn {frame, index} ->
        case Map.get(mapping, index) do
          nil ->
            {:error, "RawVideo.Mixer does not have a FrameSpec mapping for frame indexed #{inspect index} within #{inspect(mapping)}"}
          spec ->
            {frame, index, spec}
        end
      end)
      |> Enum.map(fn
        {:error, reason} -> {:error, reason}
        {frame, index, spec} ->
          if FrameSpec.is_compatible?(spec, frame) do
            :ok
          else
            {:error, "Raw video frame presented at index #{inspect index} is not compatible with its assigned spec #{inspect(spec)}"}
          end
      end)
      |> Enum.first(fn
        {:error, _} -> true
        :ok -> false
      end)

    case maybe_error do
      {:error, reason} -> {:error, reason}
      nil -> :ok
    end
  end
end
