defmodule Membrane.MP4.Demuxer.CMAF.DemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.RCPipeline, as: RCPipeline
  require Membrane.Pad, as: Pad

  alias Membrane.RCMessage
  alias Membrane.Testing.Pipeline

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.
  describe "CMAF demuxer" do
    @tag :tmp_dir
    test "demuxes fragmented MP4 with just audio track", %{tmp_dir: dir} do
      in_path = "test/fixtures/cmaf/ref_audio_concatenated.fmp4"
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          audio_output_file: audio_output_path,
          audio_pad_ref: Pad.ref(:output, 1)
        )

      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)

      assert_files_equal(audio_output_path, "test/fixtures/cmaf/ref_audio.aac")
    end

    @tag :tmp_dir
    test "demuxes fragmented MP4 with just video track", %{tmp_dir: dir} do
      in_path = "test/fixtures/cmaf/ref_video_concatenated.fmp4"
      video_output_path = Path.join(dir, "out.h264")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          video_output_file: video_output_path,
          video_pad_ref: Pad.ref(:output, 1)
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert :ok == Pipeline.terminate(pipeline)

      assert_files_equal(video_output_path, "test/fixtures/cmaf/ref_video.h264")
    end

    @tag :tmp_dir
    test "demuxes fragmented MP4 with interleaved audio and video samples", %{tmp_dir: dir} do
      in_path = "test/fixtures/cmaf/muxed_audio_video/concatenated.fmp4"
      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path,
          video_pad_ref: Pad.ref(:output, 1),
          audio_pad_ref: Pad.ref(:output, 2)
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)

      assert_files_equal(video_output_path, "test/fixtures/in_video.h264")
      assert_files_equal(audio_output_path, "test/fixtures/in_audio.aac")
    end

    @tag :tmp_dir
    test "resolves tracks from fragmented MP4 and allows to link output pads when tracks are resolved",
         %{tmp_dir: dir} do
      filename = "test/fixtures/cmaf/muxed_audio_video/concatenated.fmp4"

      pipeline =
        start_remote_pipeline!(
          filename: filename,
          file_source_chunk_size: File.stat!(filename).size - 1
        )

      assert_receive %RCMessage.Notification{
                       element: :demuxer,
                       data: {:new_tracks, [{1, _payload}, {2, _payload2}]},
                       from: _
                     },
                     2000

      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      structure = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 1))
        |> child(Membrane.AAC.Parser)
        |> child(:audio_sink, %Membrane.File.Sink{location: audio_output_path}),
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 2))
        |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
        |> child(:video_sink, %Membrane.File.Sink{location: video_output_path})
      ]

      RCPipeline.exec_actions(pipeline, spec: structure)
      assert_receive %RCMessage.EndOfStream{element: :demuxer, pad: :input}, 2000
      assert_receive %RCMessage.EndOfStream{element: :audio_sink, pad: :input}, 2000
      assert_receive %RCMessage.EndOfStream{element: :video_sink, pad: :input}, 2000
      RCPipeline.terminate(pipeline)

      assert_files_equal(video_output_path, "test/fixtures/in_video.h264")
      assert_files_equal(audio_output_path, "test/fixtures/in_audio.aac")
    end
  end

  defp start_testing_pipeline!(opts) do
    input_spec = [
      child(:file, %Membrane.File.Source{location: opts[:input_file]})
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)
    ]

    video_spec =
      if opts[:video_output_file] do
        [
          get_child(:demuxer)
          |> via_out(opts[:video_pad_ref], options: [kind: :video])
          |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
          |> child(:video_sink, %Membrane.File.Sink{location: opts[:video_output_file]})
        ]
      else
        []
      end

    audio_spec =
      if opts[:audio_output_file] do
        [
          get_child(:demuxer)
          |> via_out(opts[:audio_pad_ref], options: [kind: :audio])
          |> child(Membrane.AAC.Parser)
          |> child(:audio_sink, %Membrane.File.Sink{location: opts[:audio_output_file]})
        ]
      else
        []
      end

    Pipeline.start_link_supervised!(spec: input_spec ++ video_spec ++ audio_spec)
  end

  defp start_remote_pipeline!(opts) do
    spec =
      child(:file, %Membrane.File.Source{
        location: opts[:filename],
        chunk_size: opts[:file_source_chunk_size]
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)

    pipeline = RCPipeline.start_link!()
    RCPipeline.exec_actions(pipeline, spec: spec)
    RCPipeline.subscribe(pipeline, %RCMessage.Notification{})
    RCPipeline.subscribe(pipeline, %RCMessage.EndOfStream{})

    pipeline
  end

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end
end
