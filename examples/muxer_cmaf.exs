Mix.install([
  :membrane_core,
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand(), override: true},
  :membrane_h264_ffmpeg_plugin,
  :membrane_aac_plugin,
  :membrane_file_plugin,
  :membrane_http_adaptive_stream_plugin,
  {:membrane_aac_format, "~> 0.6.0", override: true},
  {:membrane_cmaf_format, "~> 0.4.0", override: true}
])

defmodule Example do
  use Membrane.Pipeline

  @impl true
  def handle_init(_options) do
    children = [
      video_source: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      video_parser: %Membrane.H264.FFmpeg.Parser{
        framerate: {30, 1},
        alignment: :au,
        attach_nalus?: true
      },
      video_payloader: Membrane.MP4.Payloader.H264,
      audio_source: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      audio_payloader: Membrane.MP4.Payloader.AAC,
      muxer: %Membrane.MP4.Muxer.CMAF{segment_duration: 2 |> Membrane.Time.seconds()},
      file_sink: %Membrane.HTTPAdaptiveStream.Sink{
        manifest_module: Membrane.HTTPAdaptiveStream.HLS,
        target_window_duration: 30 |> Membrane.Time.seconds(),
        target_segment_duration: 2 |> Membrane.Time.seconds(),
        persist?: true,
        storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
          directory: "hls_output"
        }
      }
    ]

    links = [
      link(:video_source)
      |> to(:video_parser)
      |> to(:video_payloader)
      |> via_in(Pad.ref(:input, :video))
      |> to(:muxer),
      link(:audio_source)
      |> to(:audio_parser)
      |> to(:audio_payloader)
      |> via_in(Pad.ref(:input, :audio))
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
