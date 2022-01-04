Mix.install([
  :membrane_core,
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()},
  :membrane_hackney_plugin,
  :membrane_h264_ffmpeg_plugin,
  :membrane_aac_plugin,
  {:membrane_file_plugin, github: "membraneframework/membrane_file_plugin"}
])

defmodule Example do
  use Membrane.Pipeline

  @samples_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/"
  @video_url @samples_url <> "ffmpeg-testsrc.h264"
  @audio_url @samples_url <> "test-audio.aac"
  @output_file System.get_env("MP4_OUTPUT_FILE", "example.mp4") |> Path.expand()

  @impl true
  def handle_init(_options) do
    children = [
      video_source: %Membrane.Hackney.Source{
        location: @video_url,
        hackney_opts: [follow_redirect: true]
      },
      video_parser: %Membrane.H264.FFmpeg.Parser{
        framerate: {30, 1},
        alignment: :au,
        attach_nalus?: true
      },
      video_payloader: Membrane.MP4.Payloader.H264,
      audio_source: %Membrane.Hackney.Source{
        location: @audio_url,
        hackney_opts: [follow_redirect: true]
      },
      audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      audio_payloader: Membrane.MP4.Payloader.AAC,
      muxer: Membrane.MP4.Muxer.ISOM,
      file_sink: %Membrane.File.Sink{location: @output_file}
    ]

    links = [
      link(:video_source)
      |> to(:video_parser)
      |> to(:video_payloader)
      |> to(:muxer),
      link(:audio_source)
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
