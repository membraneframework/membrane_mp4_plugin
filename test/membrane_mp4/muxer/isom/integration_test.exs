defmodule Membrane.MP4.Muxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline
  alias Membrane.Time

  # Fixtures used in muxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp out_path_for(filename), do: "/tmp/out_#{filename}.mp4"
  defp ref_path_for(filename), do: "test/fixtures/isom/ref_#{filename}.mp4"

  defp prepare_test(filename) do
    out_path = out_path_for(filename)
    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)
  end

  defp perform_test(pid, filename) do
    out_path = out_path_for(filename)
    ref_path = ref_path_for(filename)

    assert_end_of_stream(pid, :sink, :input)
    refute_sink_buffer(pid, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pid, blocking?: true)

    assert_files_equal(out_path, ref_path)
  end

  describe "Muxer.ISOM should mux" do
    test "single H264 track" do
      prepare_test("video")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
        |> child(:payloader, Membrane.MP4.Payloader.H264)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("video")})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "video")
    end

    test "single AAC track" do
      prepare_test("aac")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:payloader, Membrane.MP4.Payloader.AAC)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("aac")})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "aac")
    end

    test "single OPUS track" do
      prepare_test("opus")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_audio.opus"})
        |> child(:parser, %Membrane.Opus.Parser{input_delimitted?: true, delimitation: :undelimit})
        |> child(:payloader, Membrane.MP4.Payloader.Opus)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("opus")})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "opus")
    end

    test "two tracks" do
      prepare_test("two_tracks")

      structure = [
        child(:video_file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
          framerate: {30, 1},
          attach_nalus?: true
        })
        |> child(:video_payloader, Membrane.MP4.Payloader.H264),
        child(:audio_file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:audio_payloader, Membrane.MP4.Payloader.AAC),
        child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("two_tracks")}),
        get_child(:video_payloader) |> get_child(:muxer),
        get_child(:audio_payloader) |> get_child(:muxer)
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "two_tracks")
    end
  end

  describe "Muxer.ISOM with fast_start enabled should mux" do
    test "single H264 track" do
      prepare_test("video_fast_start")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
        |> child(:payloader, Membrane.MP4.Payloader.H264)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("video_fast_start")})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "video_fast_start")
    end

    test "single AAC track" do
      prepare_test("aac_fast_start")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:payloader, Membrane.MP4.Payloader.AAC)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("aac_fast_start")})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "aac_fast_start")
    end

    test "two tracks" do
      prepare_test("two_tracks_fast_start")

      structure = [
        child(:video_file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
          framerate: {30, 1},
          attach_nalus?: true
        })
        |> child(:video_payloader, Membrane.MP4.Payloader.H264),
        child(:audio_file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:audio_payloader, Membrane.MP4.Payloader.AAC),
        child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("two_tracks_fast_start")}),
        get_child(:video_payloader) |> get_child(:muxer),
        get_child(:audio_payloader) |> get_child(:muxer)
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "two_tracks_fast_start")
    end
  end

  describe "When fed a variable parameter h264 stream, Muxer.ISOM should" do
    test "raise when stream format's inband_parameters are not used" do
      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video_vp.h264"})
        |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
        |> child(:payloader, Membrane.MP4.Payloader.H264)
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: "/dev/null"})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)
      monitor_ref = Process.monitor(pid)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:shutdown, :child_crash}}, 1_000
    end

    test "be able to mux when inband_parameters are used" do
      prepare_test("h264_variable_parameters")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video_vp.h264"})
        |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
        |> child(:payloader, %Membrane.MP4.Payloader.H264{parameters_in_band?: true})
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("video_variable_parameters")})
      ]

      pid = Pipeline.start_link_supervised!(structure: structure)

      perform_test(pid, "video_variable_parameters")
    end
  end
end
