defmodule Membrane.MP4.Muxer.CMAF.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.CMAF.SegmentDurationRange
  alias Membrane.{ParentSpec, Testing, Time}

  # Fixtures used in CMAF tests below were generated using `membrane_http_adaptive_stream_plugin`
  # with `muxer_segment_duration` option set to `Membrane.Time.seconds(2)`.

  test "video" do
    assert {:ok, pipeline} = prepare_pipeline(:video)

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
    assert {:ok, pipeline} = prepare_pipeline(:audio)

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
                   segment_duration_range: SegmentDurationRange.new(Time.seconds(2))
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

  test "video partial segments" do
    assert {:ok, pipeline} =
             prepare_pipeline(:video,
               duration_range: new_duration_range(1500, 2000),
               partial_duration_range: new_duration_range(250, 500)
             )

    independent_buffers =
      1..20
      |> Enum.reduce(0, fn _i, acc ->
        assert_sink_buffer(pipeline, :sink, buffer)

        assert buffer.metadata.duration < Membrane.Time.milliseconds(600)

        if buffer.metadata.independent?, do: acc + 1, else: acc
      end)

    assert independent_buffers == 2

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "audio partial segments" do
    assert {:ok, pipeline} =
             prepare_pipeline(:audio,
               duration_range: new_duration_range(1500, 2000),
               partial_duration_range: new_duration_range(250, 500)
             )

    0..22
    |> Enum.map(fn _i ->
      assert_sink_buffer(pipeline, :sink, buffer)

      # every audio buffer should be independent
      assert buffer.metadata.independent?
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "video with partial segments should create as many partial segments as possible until reaching a key frame" do
    assert {:ok, pipeline} =
             prepare_pipeline(:video,
               duration_range: new_duration_range(1500, 2000),
               partial_duration_range: new_duration_range(250, 500)
             )

    # the video has 10 seconds where second keyframe appears after 8 seconds

    # first independent segment
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.metadata.independent?
    assert buffer.metadata.duration <= Membrane.Time.milliseconds(600)

    # partial segments for the following 8 seconds without a keyframe
    for _ <- 1..15 do
      assert_sink_buffer(pipeline, :sink, buffer)
      refute buffer.metadata.independent?
      assert buffer.metadata.duration <= Membrane.Time.milliseconds(600)
    end

    # independent part wth a keyframe
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.metadata.independent?

    assert buffer.metadata.duration <= Membrane.Time.milliseconds(600) and
             buffer.metadata.duration >= Membrane.Time.milliseconds(500)

    for _ <- 1..3 do
      assert_sink_buffer(pipeline, :sink, buffer)
      refute buffer.metadata.independent?
    end

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  defp new_duration_range(min, target),
    do: SegmentDurationRange.new(Time.milliseconds(min), Time.milliseconds(target))

  defp prepare_pipeline(type, opts \\ []) when type in [:audio, :video] do
    file =
      Keyword.get(
        opts,
        :file,
        case type do
          :audio -> "test/fixtures/in_audio.aac"
          :video -> "test/fixtures/in_video.h264"
        end
      )

    parser =
      case type do
        :audio -> %Membrane.AAC.Parser{out_encapsulation: :none}
        :video -> %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true}
      end

    payloader =
      case type do
        :audio -> Membrane.MP4.Payloader.AAC
        :video -> Membrane.MP4.Payloader.H264
      end

    duration_range = Keyword.get(opts, :duration_range, new_duration_range(2000, 2000))
    partial_duration_range = Keyword.get(opts, :partial_duration_range, nil)

    children = [
      file: %Membrane.File.Source{location: file},
      parser: parser,
      payloader: payloader,
      cmaf: %Membrane.MP4.Muxer.CMAF{
        segment_duration_range: duration_range,
        partial_segment_duration_range: partial_duration_range
      },
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} = Testing.Pipeline.start_link(links: ParentSpec.link_linear(children))
    assert_pipeline_playback_changed(pipeline, _previous_state, :playing)

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{header: header, content_type: type})
    assert_mp4_equal(header, Keyword.get(opts, :header_file, "ref_#{type}_header.mp4"))

    {:ok, pipeline}
  end

  defp assert_mp4_equal(output, ref_file) do
    ref_output = File.read!(Path.join("test/fixtures/cmaf", ref_file))
    assert {ref_file, Container.parse!(output)} == {ref_file, Container.parse!(ref_output)}
    assert {ref_file, output} == {ref_file, ref_output}
  end
end
