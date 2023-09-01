defmodule Membrane.MP4.Plugin.MixProject do
  use Mix.Project

  @version "0.29.1"
  @github_url "https://github.com/membraneframework/membrane_mp4_plugin"

  def project do
    [
      app: :membrane_mp4_plugin,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "MPEG-4 container plugin for Membrane Framework",
      package: package(),

      # docs
      name: "Membrane MP4 plugin",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 0.12.3"},
      {:membrane_mp4_format, "~> 0.8.0"},
      {:membrane_cmaf_format, "~> 0.7.0"},
      {:membrane_aac_format, "~> 0.8.0"},
      {:membrane_h264_format, "~> 0.6.0"},
      {:membrane_opus_format, "~> 0.3.0"},
      {:membrane_file_plugin, "~> 0.15.0"},
      {:membrane_h264_plugin, "~> 0.7.0"},
      {:bunch, "~> 1.5"},
      {:membrane_aac_plugin, "~> 0.16.0", only: :test},
      {:membrane_opus_plugin, "~> 0.17.0", only: :test},
      {:membrane_stream_plugin, "~> 0.3.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        Membrane.MP4,
        Membrane.MP4.Demuxer,
        Membrane.MP4.Muxer,
        Membrane.MP4.Payloader
      ],
      groups_for_modules: [
        Muxers: ~r/Membrane\.MP4\.Muxer/,
        Demuxers: ~r/Membrane\.MP4\.Demuxer/,
        Payloaders: ~r/Membrane\.MP4\.Payloader/,
        Boxes: ~r/Membrane\.MP4\..+Box$/
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end
end
