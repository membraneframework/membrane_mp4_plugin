defmodule Membrane.Element.MP4.MixProject do
  use Mix.Project

  @version "0.3.0"
  @github_url "https://github.com/membraneframework/membrane-element-udp"

  def project do
    [
      app: :membrane_element_mp4,
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
      nest_modules_by_prefix: [Membrane.Element.MP4]
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
      {:membrane_core, "~> 0.5.0"},
      {:membrane_caps_mp4,
       git: "git@github.com:membraneframework/membrane-caps-mp4", branch: "develop"},
      {:membrane_caps_http_adaptive_stream,
       git: "git@github.com:membraneframework/membrane-caps-http-adaptive-stream",
       branch: "develop"},
      {:membrane_caps_aac, github: "membraneframework/membrane-caps-aac", ref: "develop"},
      {:membrane_caps_video_h264, "~> 0.1.0"},
      {:ex_doc, "~> 0.21", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev, :test], runtime: false}
    ]
  end
end
