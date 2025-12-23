defmodule Membrane.MP4.Plugin.MixProject do
  use Mix.Project

  @version "0.36.10"
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
      docs: docs(),
      aliases: [docs: ["docs", &append_llms_links/1]]
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
      {:membrane_core, "~> 1.0"},
      {:membrane_mp4_format, "~> 0.8.0"},
      {:membrane_cmaf_format, "~> 0.7.0"},
      {:membrane_aac_format, "~> 0.8.0"},
      {:membrane_h264_format, "~> 0.6.1"},
      {:membrane_h265_format, "~> 0.2.0"},
      {:membrane_opus_format, "~> 0.3.0"},
      {:membrane_rtp_av1_plugin,
       git: "git@gitlab.com:aryk/membrane_rtp_av1_plugin.git", optional: true},
      {:membrane_file_plugin, "~> 0.17.0"},
      {:membrane_timestamp_queue, "~> 0.2.1"},
      {:bunch, "~> 1.5"},
      {:membrane_h26x_plugin, "~> 0.10.0", only: :test},
      {:membrane_aac_plugin, "~> 0.18.0", only: :test},
      {:membrane_opus_plugin, "~> 0.19.0", only: :test},
      {:membrane_stream_plugin, "~> 0.4.0", only: :test},
      {:membrane_fake_plugin, "~> 0.11.0", only: :test},
      {:ex_doc, ">= 0.40.0", only: :dev, runtime: false},
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
      File.mkdir_p!(Path.join([__DIR__, "priv", "plts"]))
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
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

  defp append_llms_links(_args) do
    output_dir = docs()[:output] || "doc"
    path = Path.join(output_dir, "llms.txt")

    if File.exists?(path) do
      existing = File.read!(path)

      footer = """


      ## See Also

      - [Membrane Framework AI Skill](https://hexdocs.pm/membrane_core/skill.md)
      - [Membrane Core](https://hexdocs.pm/membrane_core/llms.txt)
      """

      File.write!(path, String.trim_trailing(existing) <> footer)
    else
      IO.warn("#{path} not found — llms.txt was not generated, check your ex_doc configuration")
    end
  end
end
