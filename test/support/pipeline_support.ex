defmodule Membrane.VideoMixer.Test.Support.Pipeline do
  @moduledoc false

  @default_receive_timeout 4000

  @spec collect_buffers([Membrane.ChildrenSpec.builder()], keyword()) :: [map()]
  def collect_buffers(spec, opts \\ []) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    max_buffers = Keyword.get(opts, :max_buffers)

    stream = buffers_stream(spec, receive_timeout)

    case max_buffers do
      nil -> Enum.into(stream, [])
      max when is_integer(max) and max > 0 -> stream |> Stream.take(max) |> Enum.into([])
    end
  end

  @spec buffers_stream([Membrane.ChildrenSpec.builder()], non_neg_integer()) :: Enumerable.t()
  def buffers_stream(spec, receive_timeout) do
    Stream.resource(
      fn ->
        Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      end,
      fn pid ->
        receive do
          {Membrane.Testing.Pipeline, ^pid,
           {:handle_element_end_of_stream, {:sink, :input}}} ->
            {:halt, pid}

          {Membrane.Testing.Pipeline, ^pid,
           {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
            {[%{buffer: buffer, t: :erlang.monotonic_time()}], pid}
        after
          receive_timeout ->
            raise RuntimeError, "No results received within #{receive_timeout}"
        end
      end,
      fn pid -> Membrane.Pipeline.terminate(pid) end
    )
  end
end
