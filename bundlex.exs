defmodule StudioEngine.BundlexProject do
  use Bundlex.Project

  def project do
    [
      natives: natives()
    ]
  end

  defp natives() do
    [
      mix: [
        sources: ["mix.c"],
        interface: :nif,
        preprocessor: Unifex,
        pkg_configs: ["libavutil", "libavfilter"]
      ]
    ]
  end
end
