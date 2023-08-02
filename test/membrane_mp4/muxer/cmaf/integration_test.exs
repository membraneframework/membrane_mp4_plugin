defmodule Membrane.MP4.Muxer.CMAF.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.MP4.BufferLimiter
  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.CMAF.RequestMediaFinalizeSender
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

    :ok = Testing.Pipeline.terminate(pipeline)
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

    :ok = Testing.Pipeline.terminate(pipeline)
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
        segment_min_duration: Time.seconds(2)
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

    :ok = Testing.Pipeline.terminate(pipeline)
  end

  test "video partial segments" do
    pipeline =
      prepare_pipeline(:video,
        segment_min_duration: Time.seconds(2),
        chunk_target_duration: Time.milliseconds(500)
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

    :ok = Testing.Pipeline.terminate(pipeline)
  end

  test "audio partial segments" do
    pipeline =
      prepare_pipeline(:audio,
        segment_min_duration: Time.seconds(2),
        chunk_target_duration: Time.milliseconds(500)
      )

    0..20
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, :sink, buffer)
      # every audio buffer should be independent
      assert buffer.metadata.independent?
    end)

    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    :ok = Testing.Pipeline.terminate(pipeline)
  end

  test "video with partial segments should create as many partial segments as possible until reaching a key frame" do
    pipeline =
      prepare_pipeline(:video,
        segment_min_duration: Time.seconds(2),
        chunk_target_duration: Time.milliseconds(500)
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

    :ok = Testing.Pipeline.terminate(pipeline)
  end

  describe "RequestMediaFinalization" do
    @video_sample_duration Membrane.Time.microseconds(33_333)
    @audio_sample_duration Membrane.Time.microseconds(23_220)

    setup ctx do
      segment_min_duration = ctx[:segment_min_duration]
      chunk_target_duration = ctx[:chunk_target_duration]

      parent = self()

      structure = [
        child(:audio_source, %Membrane.File.Source{location: "test/fixtures/in_audio.aac"})
        |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:audio_payloader, Membrane.MP4.Payloader.AAC),
        # NOTE: keyframes are every 2 seconds
        child(:video_source, %Membrane.File.Source{location: "test/fixtures/in_video_gop_30.h264"})
        |> child(:video_parser, %Membrane.H264.FFmpeg.Parser{
          framerate: {30, 1},
          attach_nalus?: true,
          max_frame_reorder: 0
        })
        |> child(:video_payloader, Membrane.MP4.Payloader.H264),
        child(:cmaf, %Membrane.MP4.Muxer.CMAF{
          segment_min_duration: segment_min_duration,
          chunk_target_duration: chunk_target_duration
        })
        |> child(:media_finalization_sender, %RequestMediaFinalizeSender{parent: parent})
        |> child(:sink, Membrane.Testing.Sink),
        get_child(:audio_payloader)
        |> child(:audio_limiter, %BufferLimiter{parent: parent, tag: :audio})
        |> get_child(:cmaf),
        get_child(:video_payloader)
        |> child(:video_limiter, %BufferLimiter{parent: parent, tag: :video})
        |> get_child(:cmaf)
      ]

      pipeline = Testing.Pipeline.start_link_supervised!(structure: structure)
      assert_pipeline_play(pipeline)

      assert_receive {:buffer_limiter, :audio, audio_limiter}
      assert_receive {:buffer_limiter, :video, video_limiter}
      assert_receive {:media_finalize_request_sender, sender}

      [
        pipeline: pipeline,
        audio_limiter: audio_limiter,
        video_limiter: video_limiter,
        finalize_request_sender: sender
      ]
    end

    @tag segment_min_duration: Membrane.Time.seconds(6)
    test "requesting finalization should create the segment faster", %{
      pipeline: pipeline,
      audio_limiter: audio_limiter,
      video_limiter: video_limiter,
      finalize_request_sender: finalize_request_sender
    } do
      # play first couple of seconds, but less than segment minimum duration
      ref_video =
        BufferLimiter.release_buffers(
          video_limiter,
          trunc(Membrane.Time.milliseconds(1800) / @video_sample_duration)
        )

      ref_audio =
        BufferLimiter.release_buffers(
          audio_limiter,
          trunc(Membrane.Time.milliseconds(1800) / @audio_sample_duration)
        )

      :ok = Membrane.MP4.BufferLimiter.await_buffers_released(ref_video)
      :ok = Membrane.MP4.BufferLimiter.await_buffers_released(ref_audio)

      # send the finalization request
      RequestMediaFinalizeSender.send_request(finalize_request_sender)

      # play more seconds to exceed the segment minimum duration
      BufferLimiter.release_buffers(
        video_limiter,
        trunc(Membrane.Time.seconds(10) / @video_sample_duration)
      )

      BufferLimiter.release_buffers(
        audio_limiter,
        trunc(Membrane.Time.seconds(10) / @audio_sample_duration)
      )

      assert_sink_buffer(pipeline, :sink, buffer)
      assert buffer.metadata.independent?
      assert_in_delta buffer.metadata.duration, Membrane.Time.seconds(2), @video_sample_duration

      assert_end_of_stream(pipeline, :sink)
    end

    @tag segment_min_duration: Membrane.Time.seconds(6)
    test "reference segment duration without finalization request",
         %{
           pipeline: pipeline,
           audio_limiter: audio_limiter,
           video_limiter: video_limiter
         } = ctx do
      BufferLimiter.release_buffers(video_limiter, 1_000)
      BufferLimiter.release_buffers(audio_limiter, 1_000)

      assert_sink_buffer(pipeline, :sink, buffer)
      assert buffer.metadata.independent?
      assert_in_delta buffer.metadata.duration, ctx.segment_min_duration, @video_sample_duration

      assert_end_of_stream(pipeline, :sink)
    end

    @tag segment_min_duration: Membrane.Time.seconds(6)
    @tag chunk_target_duration: Membrane.Time.milliseconds(400)
    test "requesting finalization should create properly media chunks", %{
      pipeline: pipeline,
      audio_limiter: audio_limiter,
      video_limiter: video_limiter,
      finalize_request_sender: finalize_request_sender
    } do
      ref_video =
        BufferLimiter.release_buffers(
          video_limiter,
          trunc(Membrane.Time.milliseconds(1800) / @video_sample_duration)
        )

      ref_audio =
        BufferLimiter.release_buffers(
          audio_limiter,
          trunc(Membrane.Time.milliseconds(1800) / @audio_sample_duration)
        )

      :ok = Membrane.MP4.BufferLimiter.await_buffers_released(ref_video)
      :ok = Membrane.MP4.BufferLimiter.await_buffers_released(ref_audio)

      assert_sink_buffer(pipeline, :sink, buffer)
      assert buffer.metadata.independent?

      for _i <- 1..3 do
        assert_sink_buffer(pipeline, :sink, buffer)
        refute buffer.metadata.independent?
      end

      RequestMediaFinalizeSender.send_request(finalize_request_sender)

      BufferLimiter.release_buffers(video_limiter, 1_000)
      BufferLimiter.release_buffers(audio_limiter, 1_000)

      assert_sink_buffer(pipeline, :sink, buffer)
      refute buffer.metadata.independent?
      assert buffer.metadata.last_chunk?

      assert_end_of_stream(pipeline, :sink)
    end
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

    segment_min_duration = Keyword.get(opts, :segment_min_duration, Time.seconds(2))
    chunk_target_duration = Keyword.get(opts, :chunk_target_duration, nil)

    structure = [
      child(:file, %Membrane.File.Source{location: file})
      |> child(:parser, parser)
      |> child(:payloader, payloader)
      |> child(:cmaf, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: segment_min_duration,
        chunk_target_duration: chunk_target_duration
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
