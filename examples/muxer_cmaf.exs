Mix.install([
  :membrane_aac_plugin,
  :membrane_h26x_plugin,
  :membrane_hackney_plugin,
  :membrane_http_adaptive_stream_plugin,
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand(), override: true}
])

defmodule Example do
  use Membrane.Pipeline

  alias Membrane.Time
  alias Membrane.MP4.Muxer.CMAF.DurationRange
  alias Membrane.HTTPAdaptiveStream.Sink, as: HLSSink

  @samples_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/"
  @audio_url @samples_url <> "bun33s.aac"
  @video_url @samples_url <> "bun33s_720x480.h264"
  @output_dir "hls_output"

  def start_link() do
    Membrane.Pipeline.start_link(__MODULE__)
  end

  @impl true
  def handle_init(_ctx, _opts) do
    File.rm_rf(@output_dir)
    File.mkdir!(@output_dir)

    structure = [
      child(:video_source, %Membrane.Hackney.Source{
        location: @video_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:video_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {25, 1}},
        output_stream_structure: :avc1
      })
      |> via_in(Pad.ref(:input, :video))
      |> get_child(:muxer),
      child(:audio_source, %Membrane.Hackney.Source{
        location: @audio_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:audio_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, :audio))
      |> get_child(:muxer),
      child(:muxer, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: Time.seconds(4)
      })
      |> via_in(:input,
        options: [segment_duration: Time.seconds(12)]
      )
      |> child(:sink, %HLSSink{
        manifest_config: %HLSSink.ManifestConfig{
          name: "index",
          module: Membrane.HTTPAdaptiveStream.HLS
        },
        track_config: %HLSSink.TrackConfig{
          target_window_duration: Membrane.Time.seconds(30),
          persist?: true
        },
        storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
          directory: @output_dir
        }
      })
    ]

    {[spec: structure], %{}}
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
