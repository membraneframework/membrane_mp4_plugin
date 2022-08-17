defmodule Membrane.MP4.Muxer.CMAF.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.MP4.Container
  alias Membrane.{ParentSpec, Testing}

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

  test "video partial segments" do
    assert {:ok, pipeline} =
             prepare_pipeline(:video, segment_duration: 2_000, partial_segment_duration: 500)

    0..7
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)

      # every 4 partial segments we should get an independent one
      if rem(i, 4) == 0 do
        assert buffer.metadata.independent?
      else
        refute buffer.metadata.independent?
      end
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "audio partial segments" do
    assert {:ok, pipeline} =
             prepare_pipeline(:audio, segment_duration: 2_000, partial_segment_duration: 500)

    0..19
    |> Enum.map(fn _i ->
      assert_sink_buffer(pipeline, :sink, buffer)

      # every audio buffer should be independent
      assert buffer.metadata.independent?
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  # NOTE: in the future we should probably produce as many partial segments as we can until reaching a keyframe
  # instead of creating a giant one, for now the behaviour matches the behaviour of regular segments
  test "video with partial segments should assemble samples until reaching a keyframe on last part" do
    # with partial segment duration being 750ms we should be able to create 1 regular partial segments
    # while the second one will last a little bit longer until reaching the keyframe after 2s of the video
    assert {:ok, pipeline} =
             prepare_pipeline(:video, segment_duration: 1500, partial_segment_duration: 750)

    # the video has 10 seconds where second keyframe appears after 8 seconds

    # part1
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.metadata.independent?
    assert buffer.metadata.duration <= Membrane.Time.milliseconds(800)

    # part2
    assert_sink_buffer(pipeline, :sink, buffer)
    refute buffer.metadata.independent?
    assert buffer.metadata.duration >= Membrane.Time.milliseconds(7_000)

    # part3
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.metadata.independent?
    assert buffer.metadata.duration <= Membrane.Time.milliseconds(800)

    # part4
    assert_sink_buffer(pipeline, :sink, buffer)
    refute buffer.metadata.independent?

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

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

    segment_duration = Keyword.get(opts, :segment_duration, 2_000)
    partial_segment_duration = Keyword.get(opts, :partial_segment_duration, nil)

    children = [
      file: %Membrane.File.Source{location: file},
      parser: parser,
      payloader: payloader,
      cmaf: %Membrane.MP4.Muxer.CMAF{
        segment_duration: Membrane.Time.milliseconds(segment_duration),
        partial_segment_duration:
          if(partial_segment_duration,
            do: Membrane.Time.milliseconds(partial_segment_duration),
            else: nil
          )
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
