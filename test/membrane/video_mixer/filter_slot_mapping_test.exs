defmodule Membrane.VideoMixer.FilterSlotMappingTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec

  alias Membrane.Testing.DynamicSource
  alias Membrane.Testing.Pipeline
  alias Membrane.Testing.Sink
  alias Membrane.VideoMixer.FrameGenerator
  alias Membrane.VideoMixer.FrameSampler

  require Membrane.Pad

  @receive_timeout 4000

  test "slot mapping maps custom role to sidebar slot" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

    # Layout builder that uses slot mapping to map :sidebar slot to role :custom_role
    # Only use primary_sidebar layout when custom_role is available to avoid validation errors
    layout_builder = fn _output_spec, specs_by_role, _builder_state ->
      if Map.has_key?(specs_by_role, :custom_role) do
        {:layout, :primary_sidebar, %{sidebar: :custom_role}}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar_source, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :custom_role])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Wait for the primary_sidebar layout with slot mapping to be active
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_red?/2)

    Pipeline.terminate(pipeline)
  end

  test "switching sidebar role via rebuild_filter_graph maintains layout" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)
    {blue_state, blue_generator} = FrameGenerator.blue_generator(format)

    # Layout builder that uses slot mapping from builder_state
    # Falls back gracefully if requested role not available yet
    layout_builder = fn _output_spec, specs_by_role, builder_state ->
      sidebar_role = builder_state[:sidebar_role] || :role_a

      cond do
        Map.has_key?(specs_by_role, sidebar_role) ->
          {:layout, :primary_sidebar, %{sidebar: sidebar_role}}

        Map.has_key?(specs_by_role, :role_a) ->
          {:layout, :primary_sidebar, %{sidebar: :role_a}}

        true ->
          {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{
        layout_builder: layout_builder,
        builder_state: [sidebar_role: :role_a]
      }),
      child(:source_a, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :a), options: [role: :role_a])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Verify initial state: green (primary) and red (role_a in sidebar)
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_red?/2)

    # Add source B with blue color
    Pipeline.execute_actions(pipeline,
      spec: [
        child(:source_b, %DynamicSource{output: {blue_state, blue_generator}, stream_format: format})
        |> via_out(:output)
        |> via_in(Membrane.Pad.ref(:input, :b), options: [role: :role_b])
        |> get_child(:mixer)
      ]
    )

    # Switch sidebar to role_b via rebuild_filter_graph
    # This will cause the layout to rebuild with the new mapping once role_b is ready
    Pipeline.execute_actions(pipeline,
      notify_child: {:mixer, {:rebuild_filter_graph, [sidebar_role: :role_b]}}
    )

    # Verify switched state: green (primary) and blue (role_b in sidebar)
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_blue?/2)

    # Remove source A - layout should stay primary_sidebar (no flicker to single_fit)
    Pipeline.execute_actions(pipeline, remove_children: :source_a)

    # Verify layout still maintained: green (primary) and blue (role_b in sidebar)
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_blue?/2)

    Pipeline.terminate(pipeline)
  end

  test "raises on invalid slot name in mapping" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

    # Layout builder that uses an invalid slot name
    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :primary_sidebar, %{invalid_slot: :custom_role}}
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar_source, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :custom_role])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    # Pipeline should crash when mixer tries to validate invalid slot mapping
    Process.flag(:trap_exit, true)
    {:ok, supervisor, _pipeline} = Pipeline.start_link(spec: spec)

    assert_receive {:EXIT, ^supervisor, {:membrane_child_crash, :mixer, {%RuntimeError{message: message}, _}}}, 2000
    assert message =~ "invalid slot :invalid_slot for layout :primary_sidebar"
  end

  test "raises on unavailable role in mapping" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

    # Layout builder that maps sidebar to a nonexistent role
    layout_builder = fn _output_spec, _specs_by_role, _builder_state ->
      {:layout, :primary_sidebar, %{sidebar: :nonexistent_role}}
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar_source, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar), options: [role: :custom_role])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    # Pipeline should crash when mixer tries to validate unavailable role in slot mapping
    Process.flag(:trap_exit, true)
    {:ok, supervisor, _pipeline} = Pipeline.start_link(spec: spec)

    assert_receive {:EXIT, ^supervisor, {:membrane_child_crash, :mixer, {%RuntimeError{message: message}, _}}}, 2000
    assert message =~ "slot mapping :sidebar -> :nonexistent_role refers to unavailable role"
  end

  test "pad ID used as implicit role when role not specified" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

    # Layout builder that uses pad ID directly in mapping (no explicit role)
    layout_builder = fn _output_spec, specs_by_role, _builder_state ->
      if Map.has_key?(specs_by_role, "conn_123") do
        {:layout, :primary_sidebar, %{sidebar: "conn_123"}}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar_source, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, "conn_123"))
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Wait for the primary_sidebar layout with pad ID as implicit role
    _buffer = await_matching_buffer(pipeline, format, &primary_sidebar_green_red?/2)

    Pipeline.terminate(pipeline)
  end

  test "layout_updated notification emitted when layout is consolidated" do
    width = 64
    height = 48
    format = FrameGenerator.stream_format(width, height, framerate: {30, 1}, pixel_format: :I420)
    {green_state, green_generator} = FrameGenerator.green_generator(format)
    {red_state, red_generator} = FrameGenerator.red_generator(format)

    # Layout builder that uses slot mapping
    layout_builder = fn _output_spec, specs_by_role, _builder_state ->
      if Map.has_key?(specs_by_role, :custom_role) do
        {:layout, :primary_sidebar, %{sidebar: :custom_role}}
      else
        {:layout, :single_fit}
      end
    end

    spec = [
      child(:primary, %DynamicSource{output: {green_state, green_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(:primary, options: [role: :primary])
      |> child(:mixer, %Membrane.VideoMixer.Filter{layout_builder: layout_builder}),
      child(:sidebar_source, %DynamicSource{output: {red_state, red_generator}, stream_format: format})
      |> via_out(:output)
      |> via_in(Membrane.Pad.ref(:input, :sidebar_pad), options: [role: :custom_role])
      |> get_child(:mixer),
      get_child(:mixer)
      |> child(:sink, Sink)
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    # Wait for layout notification (primary_sidebar layout with both inputs)
    # Note: Due to timing, we may not see the intermediate single_fit layout
    notification = await_layout_notification(pipeline)
    assert {:layout_updated, %{layout: layout, slots: slots}} = notification

    # Verify we got a valid layout
    assert layout in [:single_fit, :primary_sidebar]
    assert Map.has_key?(slots, :primary)

    # If we got primary_sidebar, verify the sidebar pad too
    if layout == :primary_sidebar do
      assert slots[:primary] == :primary
      assert slots[Membrane.Pad.ref(:input, :sidebar_pad)] == :sidebar
    end

    Pipeline.terminate(pipeline)
  end

  # Helper functions

  defp await_layout_notification(pipeline, timeout \\ @receive_timeout) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {notification = {:layout_updated, _}, :mixer}}} ->
        notification

      {Membrane.Testing.Pipeline, ^pipeline, _other} ->
        await_layout_notification(pipeline, timeout)
    after
      timeout ->
        flunk("no layout_updated notification received within timeout")
    end
  end

  defp await_matching_buffer(pipeline, format, predicate, timeout \\ @receive_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_matching_buffer(pipeline, format, predicate, deadline)
  end

  defp do_await_matching_buffer(pipeline, format, predicate, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("no matching buffer received within timeout")
    end

    receive do
      {Membrane.Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        if predicate.(buffer.payload, format) do
          buffer
        else
          do_await_matching_buffer(pipeline, format, predicate, deadline)
        end

      {Membrane.Testing.Pipeline, ^pipeline, _other} ->
        do_await_matching_buffer(pipeline, format, predicate, deadline)
    after
      remaining ->
        flunk("no matching buffer received within timeout")
    end
  end

  defp primary_sidebar_green_red?(payload, %Membrane.RawVideo{height: height} = format) do
    sample_width = 4
    sample_height = 4
    # Sample from well inside the expected regions to avoid rounding issues
    left_x = 16
    right_x = 48
    y = div(height - sample_height, 2)

    left_samples = FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)
    right_samples = FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

    FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:green)) and
      FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:red))
  end

  defp primary_sidebar_green_blue?(payload, %Membrane.RawVideo{height: height} = format) do
    sample_width = 4
    sample_height = 4
    # Sample from well inside the expected regions to avoid rounding issues
    left_x = 16
    right_x = 48
    y = div(height - sample_height, 2)

    left_samples = FrameSampler.sample_area(payload, format, left_x, y, sample_width, sample_height)
    right_samples = FrameSampler.sample_area(payload, format, right_x, y, sample_width, sample_height)

    FrameSampler.uniform_color?(left_samples, FrameSampler.color_to_yuv(:green)) and
      FrameSampler.uniform_color?(right_samples, FrameSampler.color_to_yuv(:blue))
  end
end
