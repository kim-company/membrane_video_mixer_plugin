defmodule Membrane.VideoMixer.MasterMixerTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions
  alias Membrane.Testing.Pipeline
  alias VideoMixer.FrameSpec

  # TODO: none of these tests assert the output file. It could be an idea to
  # create them with ffmpeg's executable and compare the two.

  @tag :tmp_dir
  test "forward master video", %{tmp_dir: tmp_dir} do
    [master_path] =
      ["blue-16x9-1080-5s.h264"]
      |> Enum.map(fn name -> Path.join(["test", "fixtures", name]) end)

    master = %Membrane.File.Source{location: master_path}
    out_path = Path.join([tmp_dir, "output.h264"])

    filter_builder = fn %FrameSpec{width: w, height: h}, _inputs ->
      {"[0:v]scale=#{w}:#{h}:force_original_aspect_ratio=decrease,pad=#{w}:#{h}:-1:-1,setsar=1",
       [0]}
    end

    children = [
      master: master,
      master_parser: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      master_decoder: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer.MasterMixer{
        filter_graph_builder: filter_builder
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      link(:master)
      |> to(:master_parser)
      |> to(:master_decoder)
      |> via_in(:master)
      |> to(:mixer),
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40_000)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  @tag :tmp_dir
  test "mix two 1920x1080 5s as [blue|purple]", %{tmp_dir: tmp_dir} do
    [master, extra] =
      ["blue-16x9-1080-5s.h264", "purple-16x9-1080-5s.h264"]
      |> Enum.map(fn name -> Path.join(["test", "fixtures", name]) end)
      |> Enum.map(fn path -> %Membrane.File.Source{location: path} end)

    out_path = Path.join([tmp_dir, "output.h264"])

    filter_builder = fn %FrameSpec{width: width, height: height}, inputs
                        when length(inputs) == 2 ->
      {"[0:v]scale=#{width}/2:#{height}:force_original_aspect_ratio=decrease,pad=#{width}/2+1:#{height}:-1:-1,setsar=1[l];[1:v]scale=-1:#{height}/2,crop=#{width}/2:ih:iw/2:0,pad=#{width}/2:#{height}:-1:-1,setsar=1[r];[l][r]hstack",
       [0, 1]}
    end

    children = [
      master: master,
      extra: extra,
      master_parser: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      extra_parser: %Membrane.H264.FFmpeg.Parser{framerate: {25, 1}},
      master_decoder: Membrane.H264.FFmpeg.Decoder,
      extra_decoder: Membrane.H264.FFmpeg.Decoder,
      mixer: %Membrane.VideoMixer.MasterMixer{
        filter_graph_builder: filter_builder
      },
      encoder: Membrane.H264.FFmpeg.Encoder,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      link(:master)
      |> to(:master_parser)
      |> to(:master_decoder)
      |> via_in(:master)
      |> to(:mixer),
      link(:extra)
      |> to(:extra_parser)
      |> to(:extra_decoder)
      |> via_in(Pad.ref(:extra, 1))
      |> to(:mixer),
      # mixer
      link(:mixer)
      |> to(:encoder)
      |> to(:sink)
    ]

    assert {:ok, pipeline} = Pipeline.start_link(children: children, links: links)

    assert_end_of_stream(pipeline, :sink, :input, 40_000)
    Pipeline.terminate(pipeline, blocking?: true)
  end
end
