defmodule Membrane.MP4.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.MP4.Container
  alias Membrane.Testing

  test "video" do
    children = [
      file: %Membrane.Element.File.Source{location: "test/fixtures/in_video.h264"},
      parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      payloader: Membrane.MP4.Payloader.H264,
      cmaf: Membrane.MP4.CMAF.Muxer,
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{header: header, content_type: :video})
    assert_mp4_equal(header, "out_video_header.mp4")

    1..2
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      assert_mp4_equal(buffer.payload, "out_video_segment#{i}.m4s")
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _, 0)
  end

  test "audio" do
    children = [
      file: %Membrane.Element.File.Source{location: "test/fixtures/in_audio.aac"},
      parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      payloader: Membrane.MP4.Payloader.AAC,
      cmaf: %Membrane.MP4.CMAF.Muxer{segment_duration: Membrane.Time.seconds(4)},
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{elements: children})

    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{header: header, content_type: :audio})
    assert_mp4_equal(header, "out_audio_header.mp4")

    1..3
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      assert_mp4_equal(buffer.payload, "out_audio_segment#{i}.m4s")
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _, 0)
  end

  defp assert_mp4_equal(output, ref_file) do
    ref_output = File.read!(Path.join("test/fixtures", ref_file))
    assert {ref_file, Container.parse!(output)} == {ref_file, Container.parse!(ref_output)}
    assert {ref_file, output} == {ref_file, ref_output}
  end
end
