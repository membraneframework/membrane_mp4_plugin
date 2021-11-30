defmodule Membrane.MP4.Plugin.MixProject do
  use Mix.Project

  @version "0.10.0"
  @github_url "https://github.com/membraneframework/membrane_mp4_plugin"

  def project do
    [
      app: :membrane_mp4_plugin,
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "MPEG-4 container plugin for Membrane Framework",
      package: package(),
      name: "Membrane MP4 plugin",
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
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        Membrane.MP4,
        Membrane.MP4.Muxer,
        Membrane.MP4.Payloader
      ],
      groups_for_modules: [
        Muxers: ~r/Membrane\.MP4\.Muxer/,
        Payloaders: ~r/Membrane\.MP4\.Payloader/,
        Boxes: ~r/Membrane\.MP4\..+Box$/
      ]
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
      {:membrane_core, "~> 0.8.0"},
      {:membrane_mp4_format, "~> 0.4.0"},
      {:membrane_cmaf_format, "~> 0.4.0"},
      {:membrane_aac_format, "~> 0.5.0"},
      {:membrane_caps_video_h264, "~> 0.2.0"},
      {:membrane_file_plugin, "~> 0.7.0", only: :test},
      {:membrane_h264_ffmpeg_plugin, "~> 0.15.0", only: :test},
      {:membrane_aac_plugin, "~> 0.9.0", only: :test},
      {:ex_doc, "~> 0.25", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.5", [only: :test, env: :prod, hex: "credo", repo: "hexpm", optional: false]}
    ]
  end
end
