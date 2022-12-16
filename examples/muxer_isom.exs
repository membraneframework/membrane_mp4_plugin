Mix.install([
  {:membrane_aac_plugin, "~> 0.13.0"},
  {:membrane_h264_ffmpeg_plugin, "~> 0.25.0"},
  {:membrane_hackney_plugin, "~> 0.9.0"},
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand(), override: true}
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
      |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
        framerate: {30, 1},
        alignment: :au,
        attach_nalus?: true
      })
      |> child(:video_payloader, Membrane.MP4.Payloader.H264),
      child(:audio_source, %Membrane.Hackney.Source{
        location: @audio_url,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
      |> child(:audio_payloader, Membrane.MP4.Payloader.AAC),
      child(:muxer, Membrane.MP4.Muxer.ISOM)
      |> child(:sink, %Membrane.File.Sink{location: @output_file}),
      get_child(:audio_payloader) |> get_child(:muxer),
      get_child(:video_payloader) |> get_child(:muxer)
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
