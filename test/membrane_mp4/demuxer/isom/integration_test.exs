defmodule Membrane.MP4.Demuxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.Pad
  alias Membrane.Testing.Pipeline

  describe "Demuxer and depayloader should allow for reading of" do
    @tag :tmp_dir
    test "a single H264 track", %{tmp_dir: dir} do
      in_path = "test/fixtures/in_video.h264"
      mp4_path = Path.join(dir, "out.mp4")
      out_path = Path.join(dir, "out_video.h264")

      muxing_spec = [
        child(:file, %Membrane.File.Source{location: in_path})
        |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
        |> child(:payloader, %Membrane.H264.Parser{
          output_stream_structure: :avc1
        })
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Membrane.Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: mp4_path})
      ]

      Pipeline.start_link_supervised!(structure: muxing_spec) |> wait_for_pipeline_termination()

      demuxing_spec = [
        child(:file, %Membrane.File.Source{location: mp4_path})
        |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(Pad.ref(:output, 1))
        |> child(:depayloader, %Membrane.H264.Parser{output_stream_structure: :annexb})
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      Pipeline.start_link_supervised!(structure: demuxing_spec) |> wait_for_pipeline_termination()

      assert_files_equal(out_path, in_path)
    end

    @tag :tmp_dir
    test "a single AAC track", %{tmp_dir: dir} do
      in_path = "test/fixtures/in_audio.aac"
      mp4_path = Path.join(dir, "out.mp4")
      out_path = Path.join(dir, "out_audio.aac")

      muxing_spec = [
        child(:file, %Membrane.File.Source{location: in_path})
        |> child(:parser, %Membrane.AAC.Parser{
          in_encapsulation: :ADTS,
          out_encapsulation: :none,
          output_config: :esds
        })
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Membrane.Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: mp4_path})
      ]

      Pipeline.start_link_supervised!(structure: muxing_spec) |> wait_for_pipeline_termination()

      demuxing_spec = [
        child(:file, %Membrane.File.Source{location: mp4_path})
        |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(Pad.ref(:output, 1))
        |> child(:parser, %Membrane.AAC.Parser{
          in_encapsulation: :none,
          out_encapsulation: :ADTS
        })
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      Pipeline.start_link_supervised!(structure: demuxing_spec) |> wait_for_pipeline_termination()

      assert_files_equal(out_path, in_path)
    end

    @tag :tmp_dir
    test "H264 and AAC tracks", %{tmp_dir: dir} do
      in_video_path = "test/fixtures/in_video.h264"
      in_audio_path = "test/fixtures/in_audio.aac"

      mp4_path = Path.join(dir, "out.mp4")

      out_video_path = Path.join(dir, "out_video.h264")
      out_audio_path = Path.join(dir, "out_audio.aac")

      muxing_spec = [
        child(:file_video, %Membrane.File.Source{location: in_video_path})
        |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
          framerate: {30, 1},
          attach_nalus?: true
        })
        |> child(:video_payloader, %Membrane.H264.Parser{output_stream_structure: :avc1})
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Membrane.Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: mp4_path}),
        child(:file_audio, %Membrane.File.Source{location: in_audio_path})
        |> child(:audio_parser, %Membrane.AAC.Parser{
          in_encapsulation: :ADTS,
          out_encapsulation: :none,
          output_config: :esds
        })
        |> get_child(:muxer)
      ]

      Pipeline.start_link_supervised!(structure: muxing_spec) |> wait_for_pipeline_termination()

      demuxing_spec = [
        child(:file, %Membrane.File.Source{location: mp4_path})
        |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(Pad.ref(:output, 1))
        |> child(:depayloader_video, %Membrane.H264.Parser{output_stream_structure: :annexb})
        |> child(:sink_video, %Membrane.File.Sink{location: out_video_path}),
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 2))
        |> child(:audio_parser, %Membrane.AAC.Parser{
          in_encapsulation: :none,
          out_encapsulation: :ADTS
        })
        |> child(:sink_audio, %Membrane.File.Sink{location: out_audio_path})
      ]

      Pipeline.start_link_supervised!(structure: demuxing_spec)
      |> wait_for_pipeline_termination([:sink_audio, :sink_video])

      assert_files_equal(out_video_path, in_video_path)
      assert_files_equal(out_audio_path, in_audio_path)
    end
  end

  @tag :tmp_dir
  test "the PTS and DTS are properly read", %{tmp_dir: dir} do
    input_path = "test/fixtures/isom/ref_video_fast_start.mp4"
    out_path = Path.join(dir, "out.ms")
    ref_path = "test/fixtures/demuxed_and_depayloaded_video.ms"

    demuxing_spec = [
      child(:file, %Membrane.File.Source{location: input_path})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:depayloader_video, %Membrane.H264.Parser{output_stream_structure: :annexb})
      |> child(:serializer, Membrane.Stream.Serializer)
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised!(structure: demuxing_spec)
    |> wait_for_pipeline_termination([:sink])

    assert_files_equal(out_path, ref_path)
  end

  defp wait_for_pipeline_termination(pipeline, sink_names \\ [:sink]) do
    Enum.each(sink_names, fn sink_name ->
      assert_end_of_stream(pipeline, ^sink_name, :input)
      refute_sink_buffer(pipeline, sink_name, _buffer, 0)
    end)

    Pipeline.terminate(pipeline, blocking?: true)
  end

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end
end
