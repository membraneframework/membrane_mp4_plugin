defmodule Membrane.MP4.Demuxer.CMAF.DemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad
  require Membrane.RCPipeline

  alias Membrane.Pad
  alias Membrane.RCMessage
  alias Membrane.RCPipeline
  alias Membrane.Testing.Pipeline

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.
  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp ref_path_for(filename), do: "test/fixtures/payloaded/isom/payloaded_#{filename}"

  describe "CMAF demuxer demuxes" do
    @tag :tmp_dir
    test "fragemnted MP4 box with interleaved audio and video samples", %{tmp_dir: dir} do
      in_path = "test/fixtures/cmaf/muxed_audio_video/concatenated.fmp4"
      # video_output_path = Path.join(dir, "out.h264") |> IO.inspect(label: :OUTPUT)
      video_output_path = "out2.h264"
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline_with_two_tracks!(
          input_file: in_path,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)
    end
  end

  defp start_testing_pipeline_with_two_tracks!(opts) do
    spec = [
      child(:file, %Membrane.File.Source{location: opts[:input_file]})
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)
      |> via_out(Pad.ref(:output, :video), options: [kind: :video])
      |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
      |> child(:video_sink, %Membrane.File.Sink{location: opts[:video_output_file]}),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, :audio), options: [kind: :audio])
      |> child(:audio_sink, %Membrane.File.Sink{location: opts[:audio_output_file]})
    ]

    Pipeline.start_link_supervised!(spec: spec)
  end

  defp perform_test(pid, filename, out_path) do
    ref_path = ref_path_for(filename)

    assert_end_of_stream(pid, :sink, :input)

    assert :ok == Pipeline.terminate(pid)

    assert_files_equal(out_path, ref_path)
  end
end
