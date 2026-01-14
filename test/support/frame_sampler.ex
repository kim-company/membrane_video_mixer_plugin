defmodule Membrane.VideoMixer.FrameSampler do
  @moduledoc false

  alias Membrane.RawVideo

  @type rgb_color :: {0..255, 0..255, 0..255}

  @spec sample_center_area(binary(), RawVideo.t(), pos_integer(), pos_integer()) ::
          [{byte(), byte(), byte()}]
  def sample_center_area(payload, %RawVideo{} = format, sample_width, sample_height) do
    x = div(format.width - sample_width, 2)
    y = div(format.height - sample_height, 2)
    sample_area(payload, format, x, y, sample_width, sample_height)
  end

  @spec sample_area(
          binary(),
          RawVideo.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: [{byte(), byte(), byte()}]
  def sample_area(
        payload,
        %RawVideo{pixel_format: :I420, width: width, height: height},
        x,
        y,
        sample_width,
        sample_height
      ) do
    ensure_area!(width, height, x, y, sample_width, sample_height)

    y_size = width * height
    uv_size = div(y_size, 4)

    y_plane = binary_part(payload, 0, y_size)
    u_plane = binary_part(payload, y_size, uv_size)
    v_plane = binary_part(payload, y_size + uv_size, uv_size)

    y..(y + sample_height - 1)
    |> Enum.flat_map(fn row ->
      x..(x + sample_width - 1)
      |> Enum.map(fn col ->
        y_index = row * width + col
        uv_index = div(row, 2) * div(width, 2) + div(col, 2)

        {
          :binary.at(y_plane, y_index),
          :binary.at(u_plane, uv_index),
          :binary.at(v_plane, uv_index)
        }
      end)
    end)
  end

  def sample_area(_payload, %RawVideo{pixel_format: pixel_format}, _x, _y, _w, _h) do
    raise ArgumentError, "unsupported pixel_format for sampling: #{inspect(pixel_format)}"
  end

  @spec uniform_color?([{byte(), byte(), byte()}], {byte(), byte(), byte()}) :: boolean()
  def uniform_color?(samples, {y, u, v}) do
    Enum.all?(samples, fn {sy, su, sv} -> sy == y and su == u and sv == v end)
  end

  @spec color_to_yuv(rgb_color() | atom()) :: {byte(), byte(), byte()}
  def color_to_yuv(color) do
    {r, g, b} = normalize_color(color)

    y = 0.299 * r + 0.587 * g + 0.114 * b
    u = -0.169 * r - 0.331 * g + 0.5 * b + 128
    v = 0.5 * r - 0.419 * g - 0.081 * b + 128

    {clamp_byte(y), clamp_byte(u), clamp_byte(v)}
  end

  defp normalize_color({r, g, b}) when r in 0..255 and g in 0..255 and b in 0..255 do
    {r, g, b}
  end

  defp normalize_color(:red), do: {255, 0, 0}
  defp normalize_color(:green), do: {0, 255, 0}
  defp normalize_color(:blue), do: {0, 0, 255}
  defp normalize_color(:white), do: {255, 255, 255}
  defp normalize_color(:black), do: {0, 0, 0}
  defp normalize_color(:gray), do: {128, 128, 128}
  defp normalize_color(:yellow), do: {255, 255, 0}
  defp normalize_color(:cyan), do: {0, 255, 255}
  defp normalize_color(:magenta), do: {255, 0, 255}

  defp normalize_color(other) do
    raise ArgumentError, "unsupported color: #{inspect(other)}"
  end

  defp clamp_byte(value) do
    value
    |> round()
    |> max(0)
    |> min(255)
  end

  defp ensure_area!(width, height, x, y, sample_width, sample_height) do
    cond do
      sample_width <= 0 or sample_height <= 0 ->
        raise ArgumentError, "sample area must be positive"

      x < 0 or y < 0 ->
        raise ArgumentError, "sample area origin must be non-negative"

      x + sample_width > width or y + sample_height > height ->
        raise ArgumentError, "sample area exceeds frame bounds"

      true ->
        :ok
    end
  end
end
