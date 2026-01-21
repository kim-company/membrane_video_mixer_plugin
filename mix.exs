defmodule Membrane.VideoMixer.MixProject do
  use Mix.Project

  @version "2.1.0"
  @link "https://github.com/kim-company/membrane_video_mixer_plugin"

  def project do
    [
      app: :membrane_video_mixer_plugin,
      version: @version,
      source_url: @link,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: "Mixes multiple video inputs to a single output using ffmpeg filters."
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
      {:membrane_core, "~> 1.2"},
      {:membrane_raw_video_format, "~> 0.4"},
      {:video_mixer, "~> 2.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["KIM Keep In Mind"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @link}
    ]
  end
end
