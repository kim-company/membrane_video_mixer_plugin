defmodule MixerTest do
  use ExUnit.Case, async: false
  use Membrane.Pipeline
  import Membrane.Testing.Assertions
  require Membrane.Logger

  alias Membrane.Testing.Pipeline
  alias Mixer.Helpers

  @tag :tmp_dir
  test "mix two 1920x1080 5s", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix two 1920x1080 5s")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["blue-16x9-1080-5s.h264", "purple-16x9-1080-5s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix 16x9 1080p 5s 16x9 720p 5s", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix 16x9 1080p 5s 16x9 720p 5s")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["blue-16x9-1080-5s.h264", "purple-16x9-720-5s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix 16x9 1080p 5s 4x3 1080p 5s", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix 16x9 1080p 5s 4x3 1080p 5s")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["blue-16x9-1080-5s.h264", "red-4x3-1080-5s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix single 4x3 480p", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix single 4x3 480p")

    {[file_1] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["red-4x3-480-10s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "switch secondary 16x9 1080p", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: switch secondary 16x9 1080p")

    {[file_1, file_2, file_3] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(
        ["blue-16x9-1080-10s.h264", "purple-16x9-1080-5s.h264", "yellow-16x9-1080-5s.h264"],
        tmp_dir
      )

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      file_3: %Membrane.File.Source{location: file_3},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_3: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      decoder_3: Membrane.H264.FFmpeg.Decoder,
      merger: Membrane.VideoMerger,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:merger),
      # input 3
      link(:file_3)
      |> to(:parser_3)
      |> to(:decoder_3)
      |> to(:merger),
      # merger
      link(:merger)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix 16x9 1080p 5s 4x3 240p 10s", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix 16x9 1080p 5s 4x3 240p 10s")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["yellow-16x9-1080-5s.h264", "green-4x3-240-10s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix 16x9 1080p 10s 4x3 1080p 5s", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix 16x9 1080p 10s 4x3 1080p 5s")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["blue-16x9-1080-10s.h264", "green-4x3-1080-5s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "switch 16x9 720p to 16x9 1080p", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: switch 16x9 720p to 16x9 1080p")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(
        ["purple-16x9-720-5s.h264", "blue-16x9-1080-5s.h264"],
        tmp_dir
      )

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      merger: Membrane.VideoMerger,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:merger),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:merger),
      # merger
      link(:merger)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "switch secondary 4x3 720p to 4x3 1080p", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: switch secondary 4x3 720p to 4x3 1080p")

    {[file_1, file_2, file_3] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(
        ["yellow-16x9-1080-10s.h264", "red-4x3-720-2s.h264", "green-4x3-1080-2s.h264"],
        tmp_dir
      )

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      file_3: %Membrane.File.Source{location: file_3},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_3: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      decoder_3: Membrane.H264.FFmpeg.Decoder,
      merger: Membrane.VideoMerger,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:merger),
      # input 3
      link(:file_3)
      |> to(:parser_3)
      |> to(:decoder_3)
      |> to(:merger),
      # merger
      link(:merger)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "switch secondary 16x9 720p to 16x9 1080p", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: switch secondary 16x9 720p to 16x9 1080p")

    {[file_1, file_2, file_3] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(
        ["purple-16x9-1080-10s.h264", "yellow-16x9-720-2s.h264", "blue-16x9-1080-2s.h264"],
        tmp_dir
      )

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      file_3: %Membrane.File.Source{location: file_3},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      parser_3: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      decoder_3: Membrane.H264.FFmpeg.Decoder,
      merger: Membrane.VideoMerger,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:merger),
      # input 3
      link(:file_3)
      |> to(:parser_3)
      |> to(:decoder_3)
      |> to(:merger),
      # merger
      link(:merger)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix two 1920x1080 5s with different framerates", %{tmp_dir: tmp_dir} do
    Membrane.Logger.info("TEST: mix two 1920x1080 5s with different framerates")

    {[file_1, file_2] = _in_paths, _ref_path, out_path} =
      Helpers.prepare_paths(["blue-16x9-1080-5s-50fps.h264", "purple-16x9-1080-5s.h264"], tmp_dir)

    children = [
      file_1: %Membrane.File.Source{location: file_1},
      file_2: %Membrane.File.Source{location: file_2},
      parser_1: %Membrane.H264.FFmpeg.Parser{framerate: {50, 1}},
      parser_2: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      converter_1: %Membrane.FramerateConverter{framerate: {25, 1}},
      converter_2: %Membrane.FramerateConverter{framerate: {25, 1}},
      decoder_1: Membrane.H264.FFmpeg.Decoder,
      decoder_2: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer{
        output_caps: %Membrane.RawVideo{
          width: 1920,
          height: 1080,
          pixel_format: :I420,
          framerate: {25, 1},
          aligned: true
        }
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      # input 1
      link(:file_1)
      |> to(:parser_1)
      |> to(:decoder_1)
      |> to(:converter_1)
      |> to(:mixer),
      # input 2
      link(:file_2)
      |> to(:parser_2)
      |> to(:decoder_2)
      |> to(:converter_2)
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40000)
    Pipeline.terminate(pipeline, blocking?: true)
  end
end
