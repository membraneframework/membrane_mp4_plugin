defmodule Membrane.MP4.Muxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.MP4.Container
  alias Membrane.Testing.Pipeline
  alias Membrane.Time

  # Fixtures used in muxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.

  defp assert_mp4_equal(output_path, ref_path) do
    assert {parsed_out, <<>>} = output_path |> File.read!() |> Container.parse!()
    assert {parsed_ref, <<>>} = ref_path |> File.read!() |> Container.parse!()

    {out_mdat, out_boxes} = Keyword.pop!(parsed_out, :mdat)
    {ref_mdat, ref_boxes} = Keyword.pop!(parsed_ref, :mdat)

    assert out_boxes == ref_boxes
    # compare data separately with an error message, we don't want to print mdat to the console
    assert out_mdat == ref_mdat, "The media data of the output file differs from the reference!"
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

    assert :ok == Pipeline.terminate(pid)

    assert_mp4_equal(out_path, ref_path)
  end

  describe "Muxer.ISOM should mux" do
    test "single H264 track" do
      prepare_test("video")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:parser, %Membrane.H264.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_stream_structure: :avc1
        })
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("video")})
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "video")
    end

    test "single H265 track" do
      prepare_test("video_hevc")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video_hevc.h265"})
        |> child(:parser, %Membrane.H265.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_stream_structure: :hvc1
        })
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("video_hevc")})
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "video_hevc")
    end

    test "single AAC track" do
      prepare_test("aac")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:parser, %Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds})
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("aac")})
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "aac")
    end

    test "single OPUS track" do
      prepare_test("opus")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_audio.opus"})
        |> child(:parser, %Membrane.Opus.Parser{input_delimitted?: true, delimitation: :undelimit})
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("opus")})
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "opus")
    end

    test "two tracks" do
      prepare_test("two_tracks")

      structure = [
        child(:video_file, %Membrane.File.Source{
          location: "test/fixtures/in_video.h264",
          chunk_size: 2_000_048
        })
        |> child(:video_parser, %Membrane.H264.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_stream_structure: :avc1
        }),
        child(:audio_file, %Membrane.File.Source{
          location: "test/fixtures/in_audio.aac",
          chunk_size: 2_000_048
        })
        |> child(:audio_parser, %Membrane.AAC.Parser{
          out_encapsulation: :none,
          output_config: :esds
        }),
        child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("two_tracks")}),
        get_child(:video_parser) |> get_child(:muxer),
        get_child(:audio_parser) |> get_child(:muxer)
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "two_tracks")
    end
  end

  describe "Muxer.ISOM with fast_start enabled should mux" do
    test "single H264 track" do
      prepare_test("video_fast_start")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:parser, %Membrane.H264.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_stream_structure: :avc1
        })
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("video_fast_start")})
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "video_fast_start")
    end

    test "single AAC track" do
      prepare_test("aac_fast_start")

      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:parser, %Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds})
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("aac_fast_start")})
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "aac_fast_start")
    end

    test "two tracks" do
      prepare_test("two_tracks_fast_start")

      structure = [
        child(:video_file, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
        |> child(:video_parser, %Membrane.H264.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_stream_structure: :avc1
        }),
        child(:audio_file, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:audio_parser, %Membrane.AAC.Parser{
          out_encapsulation: :none,
          output_config: :esds
        }),
        child(:muxer, %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true})
        |> child(:sink, %Membrane.File.Sink{location: out_path_for("two_tracks_fast_start")}),
        get_child(:video_parser) |> get_child(:muxer),
        get_child(:audio_parser) |> get_child(:muxer)
      ]

      pid = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pid, "two_tracks_fast_start")
    end
  end

  describe "When fed a variable parameter h264 stream, Muxer.ISOM should" do
    test "raise when stream format's inband_parameters are not used" do
      structure = [
        child(:file, %Membrane.File.Source{location: "test/fixtures/in_video_vp.h264"})
        |> child(:parser, %Membrane.H264.Parser{
          generate_best_effort_timestamps: %{framerate: {30, 1}},
          output_stream_structure: :avc1
        })
        |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
          chunk_duration: Time.seconds(1),
          fast_start: true
        })
        |> child(:sink, Membrane.Fake.Sink.Buffers)
      ]

      {:ok, _supervisor_pid, pid} = Pipeline.start(spec: structure)
      monitor_ref = Process.monitor(pid)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid,
                      {:membrane_child_crash, :muxer,
                       {%RuntimeError{message: "ISOM Muxer doesn't support variable parameters"},
                        _stacktrace}}},
                     1_000
    end
  end
end
