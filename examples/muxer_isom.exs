Mix.install([
  {:membrane_aac_format,
   github: "membraneframework/membrane_aac_format", branch: "custom-sample-rate", override: true},
  :membrane_h264_plugin,
  :membrane_hackney_plugin,
  {:membrane_h264_format,
   git: "https://github.com/membraneframework/membrane_h264_format.git",
   ref: "ea5a3d2",
   override: true},
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])

defmodule Example do
  use Membrane.Pipeline

  @samples_url "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/"
  @video_url @samples_url <> "ffmpeg-testsrc.h264"
  @audio_url @samples_url <> "test-audio.aac"
  @output_file "example.mp4"

  @impl true
  def handle_init(_ctx, _opts) do
    structure = [
      child(:video_source, %Membrane.Hackney.Source{
        location: @video_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:video_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> child(:video_payloader, %Membrane.H264.Parser{output_stream_structure: :avc1}),
      child(:audio_source, %Membrane.Hackney.Source{
        location: @audio_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds}),
      child(:muxer, Membrane.MP4.Muxer.ISOM)
      |> child(:sink, %Membrane.File.Sink{location: @output_file}),
      get_child(:audio_parser) |> get_child(:muxer),
      get_child(:video_payloader) |> get_child(:muxer)
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
