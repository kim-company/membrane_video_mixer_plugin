defmodule Membrane.VideoMixer.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_video_mixer_plugin,
      version: "0.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 0.10.0"},
      {:membrane_raw_video_format, "~> 0.2.0"},
      {:video_mixer, github: "kim-company/video_mixer"},

      # testing
      {:membrane_file_plugin, "~> 0.12.0"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.21.5"},
      {:membrane_framerate_converter_plugin, "~> 0.5.0"}
    ]
  end
end
