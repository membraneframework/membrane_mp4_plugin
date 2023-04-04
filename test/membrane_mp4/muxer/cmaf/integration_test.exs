defmodule Membrane.MP4.Muxer.CMAF.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.CMAF.DurationRange
  alias Membrane.{Testing, Time}

  # Fixtures used in CMAF tests below were generated using `membrane_http_adaptive_stream_plugin`
  # with `muxer_segment_duration` option set to `Membrane.Time.seconds(2)`.

  test "video" do
    pipeline = prepare_pipeline(:video)

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
    pipeline = prepare_pipeline(:audio)

    1..6
    |> Enum.map(fn i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      assert_mp4_equal(buffer.payload, "ref_audio_segment#{i}.m4s")
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "muxed audio and video" do
    structure = [
      child(:audio_source, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
      |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
      |> child(:audio_payloader, Membrane.MP4.Payloader.AAC),
      child(:video_source, %Membrane.File.Source{location: "test/fixtures/in_video.h264"})
      |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
        framerate: {30, 1},
        attach_nalus?: true,
        max_frame_reorder: 0
      })
      |> child(:video_payloader, Membrane.MP4.Payloader.H264),
      child(:cmaf, %Membrane.MP4.Muxer.CMAF{
        min_segment_duration: Time.seconds(2)
      })
      |> child(:sink, Membrane.Testing.Sink),
      get_child(:audio_payloader) |> get_child(:cmaf),
      get_child(:video_payloader) |> get_child(:cmaf)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(structure: structure)

    assert_sink_stream_format(pipeline, :sink, %Membrane.CMAF.Track{
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
    pipeline =
      prepare_pipeline(:video,
        min_segment_duration: Time.seconds(2),
        target_chunk_duration: Time.milliseconds(500)
      )

    independent_buffers =
      1..21
      |> Enum.reduce(0, fn _i, acc ->
        assert_sink_buffer(pipeline, :sink, buffer)

        assert buffer.metadata.duration < Membrane.Time.milliseconds(550)

        if buffer.metadata.independent?, do: acc + 1, else: acc
      end)

    assert independent_buffers == 2

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "audio partial segments" do
    pipeline =
      prepare_pipeline(:audio,
        min_segment_duration: Time.seconds(2),
        target_chunk_duration: Time.milliseconds(500)
      )

    0..20
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      # every audio buffer should be independent
      assert buffer.metadata.independent?
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "video with partial segments should create as many partial segments as possible until reaching a key frame" do
    pipeline =
      prepare_pipeline(:video,
        min_segment_duration: Time.seconds(2),
        target_chunk_duration: Time.milliseconds(500)
      )

    # the video has 10 seconds where second keyframe appears after 8 seconds

    # first independent segment
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.metadata.independent?
    assert buffer.metadata.duration <= Membrane.Time.milliseconds(550)

    # partial segments for the following 8 seconds without a keyframe
    for _ <- 1..16 do
      assert_sink_buffer(pipeline, :sink, buffer)
      refute buffer.metadata.independent?
      assert buffer.metadata.duration <= Membrane.Time.milliseconds(550)
    end

    # independent part wth a keyframe
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.metadata.independent?

    assert buffer.metadata.duration <= Membrane.Time.milliseconds(550) and
             buffer.metadata.duration >= Membrane.Time.milliseconds(500)

    for _ <- 1..3 do
      assert_sink_buffer(pipeline, :sink, buffer)
      refute buffer.metadata.independent?
    end

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
        :audio ->
          %Membrane.AAC.Parser{out_encapsulation: :none}

        :video ->
          %Membrane.H264.FFmpeg.Parser{
            framerate: {30, 1},
            attach_nalus?: true,
            max_frame_reorder: 0
          }
      end

    payloader =
      case type do
        :audio -> Membrane.MP4.Payloader.AAC
        :video -> Membrane.MP4.Payloader.H264
      end

    min_segment_duration = Keyword.get(opts, :min_segment_duration, Time.seconds(2))
    target_chunk_duration = Keyword.get(opts, :target_chunk_duration, nil)

    structure = [
      child(:file, %Membrane.File.Source{location: file})
      |> child(:parser, parser)
      |> child(:payloader, payloader)
      |> child(:cmaf, %Membrane.MP4.Muxer.CMAF{
        min_segment_duration: min_segment_duration,
        target_chunk_duration: target_chunk_duration
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(structure: structure)
    assert_pipeline_play(pipeline)

    assert_sink_stream_format(pipeline, :sink, %Membrane.CMAF.Track{
      header: header,
      content_type: type
    })

    assert_mp4_equal(header, Keyword.get(opts, :header_file, "ref_#{type}_header.mp4"))

    pipeline
  end

  @fixtures_dir "test/fixtures/cmaf"
  defp assert_mp4_equal(output, ref_file) do
    {parsed_out, <<>>} = Container.parse!(output)
    {parsed_ref, <<>>} = Path.join(@fixtures_dir, ref_file) |> File.read!() |> Container.parse!()

    {out_mdat, out_boxes} = Keyword.pop(parsed_out, :mdat)
    {ref_mdat, ref_boxes} = Keyword.pop(parsed_ref, :mdat)

    assert out_boxes == ref_boxes

    # compare data separately with an error message, we don't want to print mdat to the console
    if ref_mdat do
      assert out_mdat, "The reference container has an mdat box, but its missing from the output!"

      assert out_mdat == ref_mdat, "The media data of the output file differs from the reference!"
    end
  end
end
