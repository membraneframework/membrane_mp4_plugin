defmodule Membrane.MP4.Muxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.Time
  alias Membrane.Testing.Pipeline

  # Fixtures used in muxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp out_path_for(filename), do: "/tmp/out_#{filename}.mp4"
  defp ref_path_for(filename), do: "test/fixtures/isom/ref_#{filename}.mp4"

  defp perform_test(pid, filename) do
    out_path = out_path_for(filename)
    ref_path = ref_path_for(filename)

    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)

    assert Pipeline.play(pid) == :ok
    assert_end_of_stream(pid, :sink, :input)
    refute_sink_buffer(pid, :sink, _, 0)

    assert :ok == Pipeline.stop_and_terminate(pid, blocking?: true)

    assert_files_equal(out_path, ref_path)
  end

  describe "Muxer.ISOM should mux" do
    test "single H264 track" do
      children = [
        file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
        parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
        sink: %Membrane.File.Sink{location: out_path_for("video")}
      ]

      assert {:ok, pid} = Pipeline.start_link(%Pipeline.Options{elements: children})

      perform_test(pid, "video")
    end

    test "single AAC track" do
      children = [
        file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
        parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        payloader: Membrane.MP4.Payloader.AAC,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
        sink: %Membrane.File.Sink{location: out_path_for("audio")}
      ]

      assert {:ok, pid} = Pipeline.start_link(%Pipeline.Options{elements: children})

      perform_test(pid, "audio")
    end

    test "two tracks" do
      children = [
        video_file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
        video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        video_payloader: Membrane.MP4.Payloader.H264,
        audio_file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
        audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        audio_payloader: Membrane.MP4.Payloader.AAC,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
        sink: %Membrane.File.Sink{location: out_path_for("two_tracks")}
      ]

      import Membrane.ParentSpec

      links = [
        link(:video_file)
        |> to(:video_parser)
        |> to(:video_payloader)
        |> to(:muxer),
        link(:audio_file)
        |> to(:audio_parser)
        |> to(:audio_payloader)
        |> to(:muxer),
        link(:muxer) |> to(:sink)
      ]

      assert {:ok, pid} = Pipeline.start_link(%Pipeline.Options{elements: children, links: links})

      perform_test(pid, "two_tracks")
    end
  end

  describe "Muxer.ISOM with fast_start enabled should mux" do
    test "single H264 track" do
      children = [
        file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
        parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: out_path_for("video_fast_start")}
      ]

      assert {:ok, pid} = Pipeline.start_link(%Pipeline.Options{elements: children})

      perform_test(pid, "video_fast_start")
    end

    test "single AAC track" do
      children = [
        file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
        parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        payloader: Membrane.MP4.Payloader.AAC,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: out_path_for("audio_fast_start")}
      ]

      assert {:ok, pid} = Pipeline.start_link(%Pipeline.Options{elements: children})

      perform_test(pid, "audio_fast_start")
    end

    test "two tracks" do
      children = [
        video_file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
        video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        video_payloader: Membrane.MP4.Payloader.H264,
        audio_file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
        audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        audio_payloader: Membrane.MP4.Payloader.AAC,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: out_path_for("two_tracks_fast_start")}
      ]

      import Membrane.ParentSpec

      links = [
        link(:video_file)
        |> to(:video_parser)
        |> to(:video_payloader)
        |> to(:muxer),
        link(:audio_file)
        |> to(:audio_parser)
        |> to(:audio_payloader)
        |> to(:muxer),
        link(:muxer) |> to(:sink)
      ]

      assert {:ok, pid} = Pipeline.start_link(%Pipeline.Options{elements: children, links: links})

      perform_test(pid, "two_tracks_fast_start")
    end
  end
end
