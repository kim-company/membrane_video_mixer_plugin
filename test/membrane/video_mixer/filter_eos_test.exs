defmodule Membrane.VideoMixer.FilterEOSTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator

  require Membrane.Pad

  @receive_timeout 4000

  # Note: Testing primary EOS scenarios is challenging because:
  # 1. The primary pad is static (:always availability) and can't be removed dynamically
  # 2. DynamicSource doesn't have a simple way to signal end_of_stream mid-pipeline
  # The primary EOS behavior (output ends when primary closes) is validated through
  # the filter's logic, but comprehensive integration testing would require additional
  # test infrastructure.

  test "removing secondary input does not end output when layout falls back" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {primary_state, primary_generator} = FrameGenerator.green_generator(format)
    {secondary_state, secondary_generator} = FrameGenerator.red_generator(format)

    # Layout builder that falls back to single_fit when secondary is not available
    layout_builder = fn _output_spec, specs_by_role, _builder_state ->
      if Map.has_key?(specs_by_role, :sidebar) do
        {:layout, :primary_sidebar}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %Membrane.Testing.DynamicSource{output: {primary_state, primary_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:secondary, %Membrane.Testing.DynamicSource{output: {secondary_state, secondary_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, 1), options: [role: :sidebar])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Skip initial stream format
    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

    # Receive buffers while both inputs are active (primary_sidebar layout)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})

    # Remove secondary
    Pipeline.execute_actions(pipeline, remove_children: :secondary)

    # Output should continue with just primary (single_fit layout)
    # After layout rebuilds, we should still get buffers
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{}, @receive_timeout)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{}, @receive_timeout)

    Pipeline.terminate(pipeline)
  end

  test "multiple secondary inputs can be removed without ending output" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {primary_state, primary_generator} = FrameGenerator.red_generator(format)
    {sec1_state, sec1_generator} = FrameGenerator.green_generator(format)
    {sec2_state, sec2_generator} = FrameGenerator.blue_generator(format)

    # Layout builder that adapts to available inputs
    layout_builder = fn _output_spec, specs_by_role, _builder_state ->
      cond do
        Map.has_key?(specs_by_role, :top_right) and Map.has_key?(specs_by_role, :bottom) ->
          {:layout, :vstack}
        Map.has_key?(specs_by_role, :bottom) ->
          {:layout, :vstack}
        true ->
          {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %Membrane.Testing.DynamicSource{output: {primary_state, primary_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :top])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sec1, %Membrane.Testing.DynamicSource{output: {sec1_state, sec1_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, 1), options: [role: :bottom])
      |> get_child(:mixer),
      child(:sec2, %Membrane.Testing.DynamicSource{output: {sec2_state, sec2_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, 2), options: [role: :top_right])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Skip initial stream format
    assert_sink_stream_format(pipeline, :sink, %Membrane.RawVideo{})

    # Receive buffers with all inputs
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{})

    # Remove sec2
    Pipeline.execute_actions(pipeline, remove_children: :sec2)

    # Should still get buffers (vstack layout with top and bottom)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{}, @receive_timeout)

    # Remove sec1
    Pipeline.execute_actions(pipeline, remove_children: :sec1)

    # Should still get buffers (single_fit layout with just primary)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{}, @receive_timeout)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{}, @receive_timeout)

    Pipeline.terminate(pipeline)
  end
end
