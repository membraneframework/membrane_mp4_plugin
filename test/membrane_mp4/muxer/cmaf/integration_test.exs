defmodule Membrane.MP4.Muxer.CMAF.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.MP4.Container
  alias Membrane.{ParentSpec, Testing}

  # Fixtures used in CMAF tests below were generated using `membrane_http_adaptive_stream_plugin`
  # with `muxer_segment_duration` option set to `Membrane.Time.seconds(2)`.

  test "video" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
      parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      payloader: Membrane.MP4.Payloader.H264,
      cmaf: %Membrane.MP4.Muxer.CMAF{
        segment_duration: Membrane.Time.seconds(2)
      },
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} = Testing.Pipeline.start_link(links: ParentSpec.link_linear(children))
    assert_pipeline_playback_changed(pipeline, _previous_state, :playing)

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{header: header, content_type: :video})
    assert_mp4_equal(header, "ref_video_header.mp4")

    1..2
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      assert_mp4_equal(buffer.payload, "ref_video_segment#{i}.m4s")
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "audio" do
    children = [
      file: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
      parser: %Membrane.AAC.Parser{out_encapsulation: :none},
      payloader: Membrane.MP4.Payloader.AAC,
      cmaf: %Membrane.MP4.Muxer.CMAF{
        segment_duration: Membrane.Time.seconds(2)
      },
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} = Testing.Pipeline.start_link(links: ParentSpec.link_linear(children))
    assert_pipeline_playback_changed(pipeline, _previous_state, :playing)

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{header: header, content_type: :audio})
    assert_mp4_equal(header, "ref_audio_header.mp4")

    1..5
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      assert_mp4_equal(buffer.payload, "ref_audio_segment#{i}.m4s")
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "muxed audio and video" do
    import Membrane.ParentSpec

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(
               children: [
                 audio_source: %Membrane.File.Source{location: "test/fixtures/in_audio.aac"},
                 video_source: %Membrane.File.Source{location: "test/fixtures/in_video.h264"},
                 audio_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
                 video_parser: %Membrane.H264.FFmpeg.Parser{
                   framerate: {30, 1},
                   attach_nalus?: true
                 },
                 audio_payloader: Membrane.MP4.Payloader.AAC,
                 video_payloader: Membrane.MP4.Payloader.H264,
                 cmaf: %Membrane.MP4.Muxer.CMAF{
                   segment_duration: Membrane.Time.seconds(2)
                 },
                 sink: Membrane.Testing.Sink
               ],
               links: [
                 link(:video_source) |> to(:video_parser) |> to(:video_payloader) |> to(:cmaf),
                 link(:audio_source) |> to(:audio_parser) |> to(:audio_payloader) |> to(:cmaf),
                 link(:cmaf) |> to(:sink)
               ]
             )

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{
      header: header,
      content_type: content_type
    })

    assert MapSet.new(content_type) |> MapSet.equal?(MapSet.new([:audio, :video]))

    assert_mp4_equal(header, "muxed_audio_video/header.mp4")

    1..2
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      assert_mp4_equal(buffer.payload, "muxed_audio_video/segment_#{i}.m4s")
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  defp assert_mp4_equal(output, ref_file) do
    ref_output = File.read!(Path.join("test/fixtures/cmaf", ref_file))
    assert {ref_file, Container.parse!(output)} == {ref_file, Container.parse!(ref_output)}
    assert {ref_file, output} == {ref_file, ref_output}
  end
end
