defmodule Membrane.MP4.Plugin.MixProject do
  use Mix.Project

  @version "0.3.0"
  @github_url "https://github.com/membraneframework/membrane_mp4_plugin"

  def project do
    [
      app: :membrane_mp4_plugin,
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Membrane Multimedia Framework (MP4 Element)",
      package: package(),
      name: "Membrane Element: MP4",
      source_url: @github_url,
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.MP4]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 0.5.2"},
      {:membrane_mp4_format, github: "membraneframework/membrane_mp4_format", branch: "develop"},
      {:membrane_cmaf_format,
       github: "membraneframework/membrane_cmaf_format", branch: "develop"},
      {:membrane_aac_format, github: "membraneframework/membrane_aac_format", branch: "develop"},
      {:membrane_http_adaptive_stream_plugin,
       github: "membraneframework/membrane_http_adaptive_stream_plugin", branch: "develop"},
      {:membrane_caps_video_h264, "~> 0.1.0"},
      {:membrane_element_file, "~> 0.3.0", only: :test},
      {:membrane_element_ffmpeg_h264,
       github: "membraneframework/membrane-element-ffmpeg-h264", branch: "nalu", only: :test},
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
