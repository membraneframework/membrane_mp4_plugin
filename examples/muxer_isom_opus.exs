Mix.install(
  [
    :membrane_core,
    {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()},
    :membrane_file_plugin,
    :membrane_opus_plugin
  ],
  force: true
)

defmodule Example do
  use Membrane.Pipeline

  alias Membrane.Caps.Audio.Raw

  @impl true
  def handle_init(_options) do
    children = [
      audio_source: %Membrane.File.Source{location: "audio.raw"},
      audio_encoder: %Membrane.Opus.Encoder{
        application: :audio,
        input_caps: %Raw{
          channels: 1,
          format: :s16le,
          sample_rate: 48_000
        }
      },
      audio_parser: %Membrane.Opus.Parser{delimitation: :undelimit},
      audio_payloader: Membrane.MP4.Payloader.Opus,
      muxer: Membrane.MP4.Muxer.ISOM,
      file_sink: %Membrane.File.Sink{location: "opus.mp4"}
    ]

    links = [
      link(:audio_source)
      |> to(:audio_encoder)
      |> to(:audio_parser)
      |> to(:audio_payloader)
      |> to(:muxer),
      link(:muxer) |> to(:file_sink)
    ]

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end

  @impl true
  def handle_element_end_of_stream({:file_sink, _}, _ctx, state) do
    Membrane.Pipeline.stop_and_terminate(self())
    {:ok, state}
  end

  def handle_element_end_of_stream(_element, _ctx, state) do
    {:ok, state}
  end
end

ref =
  Example.start_link()
  |> elem(1)
  |> tap(&Membrane.Pipeline.play/1)
  |> then(&Process.monitor/1)

receive do
  {:DOWN, ^ref, :process, _pid, _reason} ->
    :ok
end
