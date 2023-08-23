Mix.install([
  {:membrane_aac_plugin,
   git: "https://github.com/membraneframework/membrane_aac_plugin.git",
   branch: "add-config-parsing-and-generation",
   override: true},
  :membrane_hackney_plugin,
  {:membrane_h264_format,
   git: "https://github.com/membraneframework/membrane_h264_format.git",
   ref: "ea5a3d2",
   override: true},
  {:membrane_mp4_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])

defmodule Example do
  use Membrane.Pipeline

  @input_file "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.mp4"
  @output_video "example.h264"
  @output_audio "example.aac"

  @impl true
  def handle_init(_ctx, _opts) do
    structure = [
      child(:video_source, %Membrane.Hackney.Source{
        location: @input_file,
        hackney_opts: [follow_redirect: true]
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:depayloader_video, %Membrane.H264.Parser{output_stream_structure: :annexb})
      |> child(:sink_video, %Membrane.File.Sink{location: @output_video}),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, 2))
      |> child(:audio_parser, %Membrane.AAC.Parser{
        in_encapsulation: :none,
        out_encapsulation: :ADTS
      })
      |> child(:sink_audio, %Membrane.File.Sink{location: @output_audio})
    ]

    {[spec: structure], %{children_with_eos: MapSet.new()}}
  end

  # The rest of the module is used only for pipeline self-termination after processing finishes
  @impl true
  def handle_element_end_of_stream(element, _pad, _ctx, state) do
    state = %{state | children_with_eos: MapSet.put(state.children_with_eos, element)}

    actions =
      if Enum.all?([:sink_video, :sink_audio], &(&1 in state.children_with_eos)),
        do: [terminate: :shutdown],
        else: []

    {actions, state}
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
