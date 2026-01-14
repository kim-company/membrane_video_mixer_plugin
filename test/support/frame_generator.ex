defmodule Membrane.VideoMixer.FrameGenerator do
  @moduledoc false

  alias Membrane.Buffer
  alias Membrane.RawVideo

  @type color :: :red | :green | :blue | :white | :black | :gray | :yellow | :cyan | :magenta
  @type rgb_color :: {0..255, 0..255, 0..255}

  @spec stream_format(pos_integer(), pos_integer(), keyword()) :: RawVideo.t()
  def stream_format(width, height, opts \\ []) do
    %RawVideo{
      width: width,
      height: height,
      framerate: Keyword.get(opts, :framerate, {30, 1}),
      pixel_format: Keyword.get(opts, :pixel_format, :I420),
      aligned: true
    }
  end

  @spec solid_color_generator(RawVideo.t(), color() | rgb_color(), keyword()) ::
          {non_neg_integer(), Membrane.Testing.DynamicSource.generator()}
  def solid_color_generator(format, color, opts \\ []) do
    payload = solid_color_payload(format, color)
    pts_start = Keyword.get(opts, :pts_start, 0)
    pts_step = Keyword.get(opts, :pts_step, 1)

    generator = fn state, pad, buffers_cnt ->
      {buffers, next_state} = build_buffers(payload, state, buffers_cnt, pts_step)
      {[buffer: {pad, buffers}], next_state}
    end

    {pts_start, generator}
  end

  @spec red_generator(RawVideo.t(), keyword()) :: {non_neg_integer(), Membrane.Testing.DynamicSource.generator()}
  def red_generator(format, opts \\ []), do: solid_color_generator(format, :red, opts)

  @spec green_generator(RawVideo.t(), keyword()) :: {non_neg_integer(), Membrane.Testing.DynamicSource.generator()}
  def green_generator(format, opts \\ []), do: solid_color_generator(format, :green, opts)

  @spec blue_generator(RawVideo.t(), keyword()) :: {non_neg_integer(), Membrane.Testing.DynamicSource.generator()}
  def blue_generator(format, opts \\ []), do: solid_color_generator(format, :blue, opts)

  @spec solid_color_payload(RawVideo.t(), color() | rgb_color()) :: binary()
  def solid_color_payload(%RawVideo{pixel_format: :I420, width: width, height: height} = format, color) do
    ensure_even_dimensions!(format)
    {y, u, v} = rgb_to_yuv(normalize_color(color))

    y_plane = :binary.copy(<<y>>, width * height)
    uv_size = div(width * height, 4)
    u_plane = :binary.copy(<<u>>, uv_size)
    v_plane = :binary.copy(<<v>>, uv_size)

    payload = y_plane <> u_plane <> v_plane
    ensure_payload_size!(payload, format)
  end

  def solid_color_payload(%RawVideo{pixel_format: :RGB, width: width, height: height} = format, color) do
    {r, g, b} = normalize_color(color)

    payload = :binary.copy(<<r, g, b>>, width * height)
    ensure_payload_size!(payload, format)
  end

  def solid_color_payload(%RawVideo{pixel_format: :BGR, width: width, height: height} = format, color) do
    {r, g, b} = normalize_color(color)

    payload = :binary.copy(<<b, g, r>>, width * height)
    ensure_payload_size!(payload, format)
  end

  def solid_color_payload(%RawVideo{pixel_format: :RGBA, width: width, height: height} = format, color) do
    {r, g, b} = normalize_color(color)

    payload = :binary.copy(<<r, g, b, 255>>, width * height)
    ensure_payload_size!(payload, format)
  end

  def solid_color_payload(%RawVideo{pixel_format: :BGRA, width: width, height: height} = format, color) do
    {r, g, b} = normalize_color(color)

    payload = :binary.copy(<<b, g, r, 255>>, width * height)
    ensure_payload_size!(payload, format)
  end

  def solid_color_payload(%RawVideo{pixel_format: pixel_format}, _color) do
    raise ArgumentError, "unsupported pixel_format for test frames: #{inspect(pixel_format)}"
  end

  defp build_buffers(payload, pts_start, buffers_cnt, pts_step) do
    buffers =
      0..(buffers_cnt - 1)
      |> Enum.map(fn index ->
        %Buffer{payload: payload, pts: pts_start + index * pts_step}
      end)

    {buffers, pts_start + buffers_cnt * pts_step}
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

  defp rgb_to_yuv({r, g, b}) do
    y = 0.299 * r + 0.587 * g + 0.114 * b
    u = -0.169 * r - 0.331 * g + 0.5 * b + 128
    v = 0.5 * r - 0.419 * g - 0.081 * b + 128

    {clamp_byte(y), clamp_byte(u), clamp_byte(v)}
  end

  defp clamp_byte(value) do
    value
    |> round()
    |> max(0)
    |> min(255)
  end

  defp ensure_even_dimensions!(%RawVideo{width: width, height: height}) do
    if rem(width, 2) == 0 and rem(height, 2) == 0 do
      :ok
    else
      raise ArgumentError, "I420 frames require even width and height"
    end
  end

  defp ensure_payload_size!(payload, format) do
    {:ok, expected} = RawVideo.frame_size(format)

    if byte_size(payload) == expected do
      payload
    else
      raise ArgumentError, "payload size #{byte_size(payload)} does not match expected #{expected}"
    end
  end
end
