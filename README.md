# Membrane VideoMixer Plugin
Mixes multiple video inputs to a single output using ffmpeg filters. Allows
dynamic input quality switches and source addition-removal while running.

This element is used in production.

## Behavior and Policy

### Core Mixing Policy
The mixer implements a **strict synchronization policy**: output frames are produced **only when all required input pads have frames ready**. This ensures deterministic, gap-free mixing without fallback frames.

### Key Behaviors
- **Primary-driven output**: The mixer produces output based on the primary input timing and PTS values.
- **Roles are required for dynamic pads**: Each dynamic input must declare a unique `:role` atom.
- **Layouts driven by `layout_builder`**: The builder function receives frame specs for all pads and returns either:
  - `{:layout, layout_name}` - Use a predefined layout (`:single_fit`, `:hstack`, `:vstack`, `:xstack`, `:primary_sidebar`)
  - `{:raw, filter_graph}` - Use a custom FFmpeg filter graph
- **Layout changes**: When pads are added/removed, the mixer clears its filter graph cache. The layout is rebuilt lazily on the next mix operation.
- **Stream format requirements**: All inputs must provide the same fixed framerate.
- **Pad activation**: Pads become "active" when they send their **first frame** (not on stream_format). The layout is recalculated when the active pad set changes.

### Synchronization and Draining
- **Mix only when ready**: The mixer waits until all required pads (determined by the current layout) have frames queued before producing output.
- **No fallback frames**: Unlike previous versions, the mixer does not generate black frames or reuse cached frames when inputs are missing.
- **Automatic draining**: Non-required pad frames are automatically drained to prevent memory overflow while waiting for required pads.
- **Backpressure handling**: When a required input stops producing frames, the mixer stops outputting until that input resumes.

### Spec Changes
- **Spec tracking**: Frame specifications are pushed to per-pad queues on `stream_format` and popped during mixing.
- **Layout builder access**: The `layout_builder` function receives up-to-date specs for all pads that have sent stream formats.
- **Mixer rebuilding**: The FFmpeg filter graph is rebuilt when frame specs change (resolution, pixel format, etc.).

## Pad Options

### Primary Pad (`:primary`)
- `role` (atom, default: `:primary`) - The role identifier for this input
- `fit_mode` (`:crop | :fit`, default: `:crop`) - How to fit the input into its layout region

### Dynamic Input Pads (`:input`)
- `role` (atom, **required**) - Unique role identifier for this input
- `fit_mode` (`:crop | :fit`, default: `:crop`) - How to fit the input into its layout region

### Removed Options
The following options were removed in favor of the simpler synchronization policy:
- ~~`delay`~~ - Primary delay has been removed. Mixing starts immediately when all required inputs have frames.
- ~~`extra_queue_size`~~ - Queue size limits have been removed. Non-required frames are drained automatically.

## Benefits of the Current Policy

The strict synchronization policy provides several advantages:

1. **Predictable behavior**: Output is produced only when all required inputs are ready, eliminating timing-dependent edge cases.
2. **No visual artifacts**: No black frames or frozen frames from caching, ensuring clean output.
3. **Simpler implementation**: ~150 lines of complexity removed (fallback frames, black frame generation, last frame caching, delay logic).
4. **Memory bounded**: Automatic draining prevents unbounded queue growth.
5. **Clear backpressure**: When an input stops, mixing stops, making issues immediately visible.

## Migration from Previous Versions

If you're upgrading from a version that supported `delay` or `extra_queue_size`:

### Removed: Primary Delay
**Old behavior**: The `:primary` pad accepted a `:delay` option to buffer frames before mixing.

**New behavior**: Mixing starts immediately when all required pads have frames. If you need startup delay, implement it upstream of the mixer.

### Removed: Black Frames and Frame Caching
**Old behavior**: When an input hadn't sent its first frame, a black frame was used. When an input paused, its last frame was reused.

**New behavior**: The mixer waits for all required inputs to have frames. No output is produced until all required pads are ready. If you need fallback behavior, handle it in your layout_builder by conditionally excluding pads from the layout.

### Removed: Extra Queue Size
**Old behavior**: The `:input` pads accepted an `:extra_queue_size` option to limit buffering when the primary stalled.

**New behavior**: Non-required frames are automatically drained. No configuration needed.

## Installation
```elixir
def deps do
  [
    {:membrane_video_mixer_plugin, "~> 1.0.0"}
  ]
end
```

## Copyright and License
Copyright 2022, [KIM Keep In Mind GmbH](https://www.keepinmind.info/)
Licensed under the [Apache License, Version 2.0](LICENSE)
