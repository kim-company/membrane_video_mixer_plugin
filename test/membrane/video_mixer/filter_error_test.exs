defmodule Membrane.VideoMixer.FilterErrorTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator

  require Membrane.Pad

  test "raises on framerate: nil" do
    width = 64
    height = 48
    format = %Membrane.RawVideo{width: width, height: height, framerate: nil, pixel_format: :I420, aligned: true}
    {generator_state, generator} = FrameGenerator.solid_color_generator(format, :red)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :single_fit}
    end

    spec = [
      child(:primary, %DynamicSource{output: {generator_state, generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    # Pipeline should crash when mixer receives stream_format with nil framerate
    Process.flag(:trap_exit, true)
    {:ok, supervisor, _pipeline} = Pipeline.start_link(spec: spec)

    assert_receive {:EXIT, ^supervisor, {:membrane_child_crash, :mixer, {%RuntimeError{message: "mixer inputs must provide a framerate"}, _}}}, 2000
  end

  test "raises on framerate: {0, 1}" do
    width = 64
    height = 48
    format = %Membrane.RawVideo{width: width, height: height, framerate: {0, 1}, pixel_format: :I420, aligned: true}
    {generator_state, generator} = FrameGenerator.solid_color_generator(format, :red)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :single_fit}
    end

    spec = [
      child(:primary, %DynamicSource{output: {generator_state, generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary)
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    # Pipeline should crash when mixer receives stream_format with {0, 1} framerate
    Process.flag(:trap_exit, true)
    {:ok, supervisor, _pipeline} = Pipeline.start_link(spec: spec)

    assert_receive {:EXIT, ^supervisor, {:membrane_child_crash, :mixer, {%RuntimeError{message: "mixer inputs must provide a stable framerate"}, _}}}, 2000
  end

  test "raises on mismatched framerates" do
    width = 64
    height = 48
    format30fps = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    format24fps = FrameGenerator.stream_format(width, height, framerate: {24, 1}, pixel_format: :I420)

    {primary_state, primary_generator} = FrameGenerator.solid_color_generator(format30fps, :red)
    {secondary_state, secondary_generator} = FrameGenerator.solid_color_generator(format24fps, :green)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :hstack}
    end

    spec = [
      child(:primary, %DynamicSource{output: {primary_state, primary_generator}, stream_format: format30fps})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :left])  # hstack requires :left role
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:secondary, %DynamicSource{output: {secondary_state, secondary_generator}, stream_format: format24fps})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, 1), options: [role: :right])  # hstack requires :right role
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    # Pipeline should crash when mixer receives mismatched framerates
    Process.flag(:trap_exit, true)
    {:ok, supervisor, _pipeline} = Pipeline.start_link(spec: spec)

    assert_receive {:EXIT, ^supervisor, {:membrane_child_crash, :mixer, {%RuntimeError{message: message}, _}}}, 2000
    assert message =~ "all mixer inputs must agree on framerate"
    assert message =~ "{24, 1}"
    assert message =~ "{30, 1}"
  end

  test "raises on duplicate role registration" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {primary_state, primary_generator} = FrameGenerator.red_generator(format)
    {secondary_state, secondary_generator} = FrameGenerator.green_generator(format)

    layout_builder = fn _output_spec, _inputs, _builder_state ->
      {:layout, :hstack}
    end

    spec = [
      child(:primary, %DynamicSource{output: {primary_state, primary_generator}, stream_format: format})
      |> via_out(:output)
      # Primary uses role :main
      |> via_in(:primary, options: [role: :main])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:secondary, %DynamicSource{output: {secondary_state, secondary_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, 1), options: [role: :main])  # Duplicate role
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    # Pipeline should crash when mixer receives duplicate role
    Process.flag(:trap_exit, true)
    {:ok, supervisor, _pipeline} = Pipeline.start_link(spec: spec)

    assert_receive {:EXIT, ^supervisor, {:membrane_child_crash, :mixer, {%RuntimeError{message: message}, _}}}, 2000
    assert message =~ "duplicate role"
    assert message =~ ":main"
  end
end
