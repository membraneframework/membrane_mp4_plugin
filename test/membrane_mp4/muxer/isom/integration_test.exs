defmodule Membrane.MP4.Muxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.{ParentSpec, Time}
  alias Membrane.Testing.Pipeline

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

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/video.h264"},
        parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
        sink: %Membrane.File.Sink{location: out_path_for("video")}
      ]

      assert {:ok, pid} = Pipeline.start_link(links: ParentSpec.link_linear(children))

      perform_test(pid, "video")
    end

    test "single AAC track" do
      prepare_test("aac")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/audio.aac"},
        parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        payloader: Membrane.MP4.Payloader.AAC,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
        sink: %Membrane.File.Sink{location: out_path_for("aac")}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))

      perform_test(pid, "aac")
    end

    test "single OPUS track" do
      prepare_test("opus")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/audio.opus"},
        parser: %Membrane.Opus.Parser{input_delimitted?: true, delimitation: :undelimit},
        payloader: Membrane.MP4.Payloader.Opus,
        muxer: Membrane.MP4.Muxer.ISOM,
        sink: %Membrane.File.Sink{location: out_path_for("opus")}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))

      perform_test(pid, "opus")
    end

    test "two tracks" do
      prepare_test("two_tracks")

      children = [
        video_file: %Membrane.File.Source{location: "test/fixtures/video.h264"},
        video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        video_payloader: Membrane.MP4.Payloader.H264,
        audio_file: %Membrane.File.Source{location: "test/fixtures/audio.aac"},
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

      assert {:ok, pid} = Pipeline.start_link(children: children, links: links)

      perform_test(pid, "two_tracks")
    end
  end

  describe "Muxer.ISOM with fast_start enabled should mux" do
    test "single H264 track" do
      prepare_test("video_fast_start")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/video.h264"},
        parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: out_path_for("video_fast_start")}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))

      perform_test(pid, "video_fast_start")
    end

    test "single AAC track" do
      prepare_test("audio_fast_start")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/audio.aac"},
        parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        payloader: Membrane.MP4.Payloader.AAC,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: out_path_for("aac_fast_start")}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))

      perform_test(pid, "aac_fast_start")
    end

    test "two tracks" do
      prepare_test("two_tracks_fast_start")

      children = [
        video_file: %Membrane.File.Source{location: "test/fixtures/video.h264"},
        video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        video_payloader: Membrane.MP4.Payloader.H264,
        audio_file: %Membrane.File.Source{location: "test/fixtures/audio.aac"},
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

      assert {:ok, pid} = Pipeline.start_link(children: children, links: links)

      perform_test(pid, "two_tracks_fast_start")
    end
  end

  describe "When fed a variable parameter h264 stream, Muxer.ISOM should" do
    test "raise when caps inband_parameters are not used" do
      children = [
        file: %Membrane.File.Source{location: "test/fixtures/video_vp.h264"},
        parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: "/dev/null"}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))
      monitor_ref = Process.monitor(pid)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:shutdown, :child_crash}}, 1_000
    end

    test "be able to mux when inband_parameters are used" do
      prepare_test("h264_variable_parameters")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/video_vp.h264"},
        parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
        payloader: %Membrane.MP4.Payloader.H264{parameters_in_band?: true},
        muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
        sink: %Membrane.File.Sink{location: out_path_for("h264_variable_parameters")}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))

      perform_test(pid, "h264_variable_parameters")
    end
  end
end
