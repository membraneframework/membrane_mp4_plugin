Mix.install([
  {:membrane_aac_plugin, "~> 0.13.0"},
  {:membrane_h264_ffmpeg_plugin, "~> 0.25.0"},
  {:membrane_hackney_plugin, "~> 0.9.0"},
  {:membrane_http_adaptive_stream_plugin, "~> 0.10.0"},
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand(), override: true}
])

defmodule Example do
  use Membrane.Pipeline

  alias Membrane.HTTPAdaptiveStream.Sink, as: HLSSink

  @samples_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/"
  @audio_url @samples_url <> "bun33s.aac"
  @video_url @samples_url <> "bun33s_720x480.h264"
  @output_dir "hls_output"

  @impl true
  def handle_init(_ctx, _opts) do
    File.rm_rf(@output_dir)
    File.mkdir!(@output_dir)

    segment_duration_opts = [
      segment_duration: HLSSink.SegmentDuration.new(Membrane.Time.seconds(6))
    ]

    structure = [
      child(:video_source, %Membrane.Hackney.Source{
        location: @video_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
        framerate: {25, 1},
        alignment: :au,
        attach_nalus?: true
      })
      |> child(:video_payloader, Membrane.MP4.Payloader.H264),
      child(:audio_source, %Membrane.Hackney.Source{
        location: @audio_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:audio_parser, %Membrane.AAC.Parser{
        in_encapsulation: :ADTS,
        out_encapsulation: :none
      })
      |> child(:audio_payloader, Membrane.MP4.Payloader.AAC),
      child(:muxer, Membrane.MP4.Muxer.CMAF)
      |> child(:sink, %HLSSink{
        manifest_module: Membrane.HTTPAdaptiveStream.HLS,
        target_window_duration: Membrane.Time.seconds(30),
        persist?: true,
        storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
          directory: @output_dir
        }
      }),
      get_child(:audio_payloader)
      |> via_in(Pad.ref(:input, :audio, options: segment_duration_opts))
      |> get_child(:muxer),
      get_child(:video_payloader)
      |> via_in(Pad.ref(:input, :video, options: segment_duration_opts))
      |> get_child(:muxer)
    ]

    {[spec: structure, playback: :playing], %{}}
  end

  # The rest of the module is used only for pipeline self-termination after processing finishes
  @impl true
  def handle_element_end_of_stream(:sink, _pad, _ctx, state) do
    {[terminate: :shutdown], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end
end

# Start and monitor the pipeline
{:ok, _supervisor_pid, pipeline_pid} = Example.start_link()
ref = Process.monitor(pipeline_pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^ref, :process, _pipeline_pid, _reason} ->
    :ok
end
