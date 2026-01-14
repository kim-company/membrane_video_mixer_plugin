# Membrane VideoMixer Plugin
Mixes multiple video inputs to a single output using ffmpeg filters. Allows
dynamic input quality switches and source addition-removal while running.

This element is used in production.

## Behavior and edge cases
- Primary-driven output: the mixer produces output based on the primary input timing.
- Roles are required for dynamic pads: each dynamic input must declare a unique `:role`.
- Layouts are driven by `layout_builder`, which can return `{:layout, layout_name}` or
  `{:raw, {filter_graph, filter_indexes}}`.
- Layout changes: when pads are added/removed, the mixer rebuilds the filter graph.
- Stream format requirements: all inputs must provide the same fixed framerate.
- Missing extra frames: if an extra pad has not produced a frame yet, the mixer uses
  a black frame; once available, it reuses the last frame when the extra pauses.
- Primary delay: the `:primary` pad supports a `:delay` option (Membrane.Time) that
  waits for a configurable amount of primary frames before emitting output.
- Primary stalls: when the primary input stops producing, extra inputs are trimmed
  using `extra_queue_size` with a drop-oldest strategy to avoid unbounded buffering.

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
