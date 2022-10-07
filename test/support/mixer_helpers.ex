defmodule Mixer.Helpers do
  import ExUnit.Assertions

  @spec prepare_paths([String.t()], String.t()) ::
          {[String.t()], String.t(), String.t()}
  def prepare_paths(input_paths, tmp_dir) do
    input_paths =
      input_paths
      |> Enum.map(fn path ->
        "../fixtures/#{path}" |> Path.expand(__DIR__)
      end)

    ref_path = Path.join(tmp_dir, "reference.h264")
    out_path = Path.join(tmp_dir, "output.h264")

    {input_paths, ref_path, out_path}
  end

  @spec create_ffmpeg_reference([String.t()], String.t(), String.t()) :: nil | :ok
  def create_ffmpeg_reference(input_paths, ref_path, filter_descr) do
    inputs =
      input_paths
      |> Enum.map(fn path -> ["-i", path] end)
      |> List.flatten()

    args = ["-y"] ++ inputs ++ ["-filter_complex", filter_descr, ref_path]

    {result, exit_status} = System.cmd("ffmpeg", args, stderr_to_stdout: true)

    if exit_status != 0 do
      raise inspect(result)
    end
  end

  @spec compare_contents(String.t(), String.t()) :: true
  def compare_contents(output_path, reference_path) do
    {:ok, reference_file} = File.read(reference_path)
    {:ok, output_file} = File.read(output_path)

    assert output_file == reference_file
  end
end
