defmodule Membrane.MP4.Muxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.{Testing, Time}
  alias Membrane.MP4.Container

  # Fixtures used in muxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.

  test "video" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      payloader: Membrane.MP4.Payloader.H264,
      muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    assert_pipeline_output_matches_fixture(pipeline, "out_video.mp4")
  end

  test "audio" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      payloader: Membrane.MP4.Payloader.AAC,
      muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1)},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    assert_pipeline_output_matches_fixture(pipeline, "out_audio.mp4")
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
      sink: Membrane.Testing.Sink
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

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{
               elements: children,
               links: links
             })

    assert_pipeline_output_matches_fixture(pipeline, "out_two_tracks.mp4")
  end

  test "video fast_start" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      payloader: Membrane.MP4.Payloader.H264,
      muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    assert_pipeline_output_matches_fixture(pipeline, "out_video_fast_start.mp4")
  end

  test "audio fast_start" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      payloader: Membrane.MP4.Payloader.AAC,
      muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    assert_pipeline_output_matches_fixture(pipeline, "out_audio_fast_start.mp4")
  end

  test "two tracks fast_start" do
    children = [
      video_file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      video_payloader: Membrane.MP4.Payloader.H264,
      audio_file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      audio_payloader: Membrane.MP4.Payloader.AAC,
      muxer: %Membrane.MP4.Muxer.ISOM{chunk_duration: Time.seconds(1), fast_start: true},
      sink: Membrane.Testing.Sink
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

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{
               elements: children,
               links: links
             })

    :ok = Testing.Pipeline.play(pipeline)

    assert_pipeline_output_matches_fixture(pipeline, "out_two_tracks_fast_start.mp4")
  end

  defp assert_pipeline_output_matches_fixture(pipeline, fixture_path) do
    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: mp4})
    assert_mp4_equal(mp4, fixture_path)

    assert_end_of_stream(pipeline, :sink)

    :ok = Testing.Pipeline.stop_and_terminate(pipeline, blocking?: true)
  end

  defp assert_mp4_equal(output, ref_file) do
    ref_output = File.read!(Path.join("test/fixtures/isom", ref_file))
    assert {ref_file, Container.parse!(output)} == {ref_file, Container.parse!(ref_output)}
    assert {ref_file, output} == {ref_file, ref_output}
  end
end
