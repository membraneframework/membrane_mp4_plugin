Mix.install([
  :membrane_core,
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand(), override: true},
  :membrane_h264_ffmpeg_plugin,
  {:membrane_aac_plugin, "~> 0.11.1"},
  :membrane_hackney_plugin,
  {:membrane_http_adaptive_stream_plugin,
   github: "membraneframework/membrane_http_adaptive_stream_plugin",
   branch: "MS-20-adapt-hls-sink-to-mux-audio-and-video",
   override: true},
  {:membrane_aac_format, "~> 0.6.0", override: true},
  {:membrane_cmaf_format, "~> 0.4.0", override: true}
])

defmodule Example do
  use Membrane.Pipeline

  @output_dir "hls_output"
  @audio "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.aac"
  @video "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s_720x480.h264"

  @impl true
  def handle_init(_options) do
    File.rm_rf(@output_dir)
    File.mkdir!(@output_dir)

    children = [
      video_source: %Membrane.Hackney.Source{
        location: @video,
        hackney_opts: [follow_redirect: true]
      },
      video_parser: %Membrane.H264.FFmpeg.Parser{
        framerate: {25, 1},
        alignment: :au,
        attach_nalus?: true
      },
      video_payloader: Membrane.MP4.Payloader.H264,
      audio_source: %Membrane.Hackney.Source{
        location: @audio,
        hackney_opts: [follow_redirect: true]
      },
      audio_parser: %Membrane.AAC.Parser{in_encapsulation: :ADTS, out_encapsulation: :none},
      audio_payloader: Membrane.MP4.Payloader.AAC,
      muxer: %Membrane.MP4.Muxer.CMAF{segment_duration: 2 |> Membrane.Time.seconds()},
      sink: %Membrane.HTTPAdaptiveStream.Sink{
        manifest_module: Membrane.HTTPAdaptiveStream.HLS,
        target_window_duration: 30 |> Membrane.Time.seconds(),
        target_segment_duration: 2 |> Membrane.Time.seconds(),
        persist?: true,
        storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
          directory: @output_dir
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
      link(:muxer) |> to(:sink)
    ]

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end

  # Rest of the module is only used for self-termination of the pipeline after processing finishes
  @impl true
  def handle_element_end_of_stream({:sink, _}, _ctx, state) do
    Membrane.Pipeline.stop_and_terminate(self())
    {:ok, state}
  end

  def handle_element_end_of_stream(_element, _ctx, state) do
    {:ok, state}
  end
end

# Start the pipeline and activate it
{:ok, pid} = Example.start_link()
:ok = Example.play(pid)

monitor_ref = Process.monitor(pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
    :ok
end
