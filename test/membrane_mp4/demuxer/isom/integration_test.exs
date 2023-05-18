defmodule Membrane.MP4.Demuxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.Testing.Pipeline
  alias Membrane.Pad

  describe "Demuxer and depayloader should allow for reading of" do
    @tag :tmp_dir
    test "a single H264 track", %{tmp_dir: dir} do
      in_path = "test/fixtures/in_video.h264"
      mp4_path = Path.join(dir, "out.mp4")
      out_path = Path.join(dir, "out_video.h264")

      muxing_spec = [
        child(:file, %Membrane.File.Source{location: in_path})
        |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
        |> child(:payloader, Membrane.MP4.Payloader.H264)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Membrane.Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: mp4_path})
      ]

      run_pipeline(muxing_spec)

      demuxing_spec = [
        child(:file, %Membrane.File.Source{location: mp4_path})
        |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(Pad.ref(:output, 1))
        |> child(:depayloader, Membrane.MP4.Depayloader.H264)
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      run_pipeline(demuxing_spec)

      assert_files_equal(out_path, in_path)
    end

    @tag :tmp_dir
    test "a single AAC track", %{tmp_dir: dir} do
      in_path = "test/fixtures/in_audio.aac"
      ref_path = Path.join(dir, "out_audio_ref.aac")
      mp4_path = Path.join(dir, "out.mp4")
      out_path = Path.join(dir, "out_audio.aac")

      muxing_spec = [
        child(:file, %Membrane.File.Source{location: in_path})
        |> child(:parser, %Membrane.AAC.Parser{
          in_encapsulation: :ADTS,
          out_encapsulation: :none
        })
        |> child(:split, Membrane.Tee.Parallel)
        |> child(:payloader, Membrane.MP4.Payloader.AAC)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Membrane.Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: mp4_path}),
        get_child(:split)
        |> child({:sink, :original}, %Membrane.File.Sink{location: ref_path})
      ]

      run_pipeline(muxing_spec)

      demuxing_spec = [
        child(:file, %Membrane.File.Source{location: mp4_path})
        |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(Pad.ref(:output, 1))
        |> child(:depayloader, Membrane.MP4.Depayloader.AAC)
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      run_pipeline(demuxing_spec)

      assert_files_equal(out_path, ref_path)
    end

    @tag :tmp_dir
    test "H264 and AAC tracks", %{tmp_dir: dir} do
      in_video_path = "test/fixtures/in_video.h264"
      in_audio_path = "test/fixtures/in_audio.aac"
      ref_audio_path = Path.join(dir, "audio_ref.aac")
      mp4_path = Path.join(dir, "out.mp4")
      out_video_path = Path.join(dir, "out_video.h264")
      out_audio_path = Path.join(dir, "out_audio.aac")

      muxing_spec = [
        child(:file_video, %Membrane.File.Source{location: in_video_path})
        |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
          framerate: {30, 1},
          attach_nalus?: true
        })
        |> child(:video_payloader, Membrane.MP4.Payloader.H264)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Membrane.Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: mp4_path}),
        child(:file_audio, %Membrane.File.Source{location: in_audio_path})
        |> child(:audio_parser, %Membrane.AAC.Parser{
          in_encapsulation: :ADTS,
          out_encapsulation: :none
        })
        |> child(:split_audio, Membrane.Tee.Parallel)
        |> child(:audio_payloader, Membrane.MP4.Payloader.AAC)
        |> get_child(:muxer),
        get_child(:split_audio)
        |> child({:sink, :original_audio}, %Membrane.File.Sink{location: ref_audio_path})
      ]

      run_pipeline(muxing_spec)

      demuxing_spec = [
        child(:file, %Membrane.File.Source{location: mp4_path})
        |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(Pad.ref(:output, 1))
        |> child(:depayloader_video, Membrane.MP4.Depayloader.H264)
        |> child(:sink_video, %Membrane.File.Sink{location: out_video_path}),
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 2))
        |> child(:depayloader_audio, Membrane.MP4.Depayloader.AAC)
        |> child(:sink_audio, %Membrane.File.Sink{location: out_audio_path})
      ]

      pipeline = Pipeline.start_link_supervised!(structure: demuxing_spec)
      assert_end_of_stream(pipeline, :sink_video, :input)
      assert_end_of_stream(pipeline, :sink_audio, :input)
      refute_sink_buffer(pipeline, :sink_video, _buffer, 0)
      refute_sink_buffer(pipeline, :sink_audio, _buffer, 0)
      Pipeline.terminate(pipeline, blocking?: true)

      assert_files_equal(out_video_path, in_video_path)
      assert_files_equal(out_audio_path, ref_audio_path)
    end
  end

  defp run_pipeline(spec) do
    pipeline = Pipeline.start_link_supervised!(structure: spec)
    assert_end_of_stream(pipeline, :sink, :input)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)
    Pipeline.terminate(pipeline, blocking?: true)
  end

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end
end
