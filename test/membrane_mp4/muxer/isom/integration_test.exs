defmodule Membrane.MP4.Muxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.MP4.Container
  alias Membrane.Testing

  # Fixtures used in muxer tests below were generated with `samples_per_chunk` option set to `10`.

  test "video" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      payloader: Membrane.MP4.Payloader.H264,
      muxer: %Membrane.MP4.Muxer.ISOM{tracks: 1, samples_per_chunk: 10},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: mp4})
    assert_mp4_equal(mp4, "out_video.mp4")

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _, 0)

    :ok = Testing.Pipeline.stop_and_terminate(pipeline, blocking?: true)
  end

  test "audio" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      payloader: Membrane.MP4.Payloader.AAC,
      muxer: %Membrane.MP4.Muxer.ISOM{tracks: 1, samples_per_chunk: 10},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: mp4})
    assert_mp4_equal(mp4, "out_audio.mp4")

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _, 0)

    :ok = Testing.Pipeline.stop_and_terminate(pipeline, blocking?: true)
  end

  test "muxer two tracks" do
    children = [
      video_file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      video_payloader: Membrane.MP4.Payloader.H264,
      audio_file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      audio_payloader: Membrane.MP4.Payloader.AAC,
      sequential: Membrane.MP4.Support.Sequential,
      muxer: %Membrane.MP4.Muxer.ISOM{tracks: 2, samples_per_chunk: 10},
      sink: Membrane.Testing.Sink
    ]

    import Membrane.ParentSpec

    links = [
      link(:video_file)
      |> to(:video_parser)
      |> to(:video_payloader)
      |> via_in(:primary_in)
      |> to(:sequential)
      |> via_out(:primary_out)
      |> to(:muxer),
      link(:audio_file)
      |> to(:audio_parser)
      |> to(:audio_payloader)
      |> via_in(:secondary_in)
      |> to(:sequential)
      |> via_out(:secondary_out)
      |> to(:muxer),
      link(:muxer) |> to(:sink)
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{
               elements: children,
               links: links
             })

    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: mp4})
    assert_mp4_equal(mp4, "out_two_tracks.mp4")

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _, 0)

    :ok = Testing.Pipeline.stop_and_terminate(pipeline, blocking?: true)
  end

  defp assert_mp4_equal(output, ref_file) do
    ref_output = File.read!(Path.join("test/fixtures/muxer", ref_file))
    assert {ref_file, Container.parse!(output)} == {ref_file, Container.parse!(ref_output)}
    assert {ref_file, output} == {ref_file, ref_output}
  end
end
