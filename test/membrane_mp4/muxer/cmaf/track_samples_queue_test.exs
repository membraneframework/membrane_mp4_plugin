defmodule Membrane.MP4.Muxer.CMAF.TrackSamplesQueueTest do
  use ExUnit.Case, async: true

  alias Membrane.MP4.Muxer.CMAF.DurationRange
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: Queue

  defp with_buffer(opts) do
    dts = Keyword.fetch!(opts, :dts)
    duration = Keyword.fetch!(opts, :duration)

    %Membrane.Buffer{payload: <<>>, dts: dts, metadata: %{duration: duration}}
  end

  defp with_keyframe_buffer(opts) do
    dts = Keyword.fetch!(opts, :dts)
    duration = Keyword.fetch!(opts, :duration)
    keyframe? = Keyword.fetch!(opts, :keyframe?)

    %Membrane.Buffer{
      payload: <<>>,
      dts: dts,
      metadata: %{duration: duration, mp4_payload: %{key_frame?: keyframe?}}
    }
  end

  @default_duration_range DurationRange.new(5, 10)

  defp empty_video_queue(duration_range \\ @default_duration_range),
    do: %Queue{track_with_keyframes?: true, duration_range: duration_range}

  defp empty_audio_queue(duration_range \\ @default_duration_range),
    do: %Queue{track_with_keyframes?: false, duration_range: duration_range}

  defp with_collectable(queue), do: %Queue{queue | collectable?: true}

  describe "Pushing to queue using plain_push_until_target/3 should" do
    test "not change to collectable state when the track's duration is smaller than min duration" do
      # given
      audio_queue = empty_audio_queue()
      video_queue = empty_video_queue()
      refute audio_queue.collectable?
      refute video_queue.collectable?

      # when
      audio_buffer = with_buffer(dts: 5, duration: 1)
      video_buffer1 = with_keyframe_buffer(dts: 5, duration: 1, keyframe?: false)
      video_buffer2 = with_keyframe_buffer(dts: 6, duration: 1, keyframe?: true)

      audio_queue = Queue.plain_push_until_target(audio_queue, audio_buffer, 10)

      video_queue =
        video_queue
        |> Queue.plain_push_until_target(video_buffer1, 10)
        |> Queue.plain_push_until_target(video_buffer2, 10)

      # then
      refute audio_queue.collectable?
      refute video_queue.collectable?
    end

    test "change to collectable state when track's duration exceeds the max duration" do
      # given
      audio_queue = empty_audio_queue()
      video_queue = empty_video_queue()
      refute audio_queue.collectable?
      refute video_queue.collectable?

      # when
      audio_buffer = with_buffer(dts: 20, duration: 1)
      video_buffer = with_keyframe_buffer(dts: 20, duration: 1, keyframe?: false)

      audio_queue = Queue.plain_push_until_target(audio_queue, audio_buffer, 10)
      video_queue = Queue.plain_push_until_target(video_queue, video_buffer, 10)

      # then
      assert audio_queue.collectable?
      assert video_queue.collectable?
    end

    test "keep collecting when track's duration exceeds the max duration" do
      # given
      queue = empty_video_queue()
      refute queue.collectable?

      # when
      buf1 = with_keyframe_buffer(dts: 30, duration: 10, keyframe?: false)
      buf2 = with_keyframe_buffer(dts: 40, duration: 10, keyframe?: false)

      queue =
        queue
        |> Queue.plain_push_until_target(buf1, 10)
        |> Queue.plain_push_until_target(buf2, 10)

      # then
      assert queue.collectable?
      assert queue.excess_samples == [buf2, buf1]
    end

    test "put samples in excess samples group when queue is already collectable" do
      # given
      queue = empty_audio_queue() |> with_collectable()
      assert queue.target_samples == []

      # when
      buffer = with_buffer(dts: 20, duration: 10)
      queue = Queue.plain_push_until_target(queue, buffer, 10)

      # then
      assert queue.target_samples == []
      assert queue.excess_samples == [buffer]
    end

    test "keep accumulated duration of target samples" do
      # given
      queue = empty_audio_queue()
      assert queue.collected_samples_duration == 0

      # when
      buf1 = with_buffer(dts: 10, duration: 5)
      buf2 = with_buffer(dts: 10, duration: 10)

      queue =
        queue
        |> Queue.plain_push_until_target(buf1, 30)
        |> Queue.plain_push_until_target(buf2, 30)

      # then
      assert queue.collected_samples_duration == buf1.metadata.duration + buf2.metadata.duration
    end
  end

  describe "Pushing to queue using push_until_target/3 or push_until_end/3 should" do
    test "result in a proper collection once in collectable state" do
      # given
      queue = empty_audio_queue(DurationRange.new(10, 15))

      # when
      buf1 = with_buffer(dts: 10, duration: 1)
      # buf2 should cause the collection
      buf2 = with_buffer(dts: 30, duration: 1)

      queue =
        queue
        |> Queue.push_until_target(buf1, 10)
        |> Queue.push_until_target(buf2, 10)

      # then
      assert queue.collectable?

      {samples, queue} = Queue.collect(queue)

      assert samples == [buf1]
      refute queue.collectable?
      assert queue.target_samples == [buf2]
    end

    test "change to collectable state when video's track exceeds target duration and the sample is a keyframe" do
      # given
      queue = empty_video_queue(DurationRange.new(10, 20))
      refute queue.collectable?

      # when
      buffer = with_keyframe_buffer(dts: 30, duration: 1, keyframe?: true)
      queue = Queue.push_until_end(queue, buffer, 0)

      # then
      assert queue.collectable?
    end

    test "not change to collectable state when tracks's duration is lower than target and max duration" do
      # given
      queue = empty_audio_queue(DurationRange.new(10, 20))
      refute queue.collectable?

      # when
      buf1 = with_buffer(dts: 15, duration: 1)
      buf2 = with_buffer(dts: 25, duration: 1)

      queue =
        queue
        |> Queue.push_until_end(buf1, 10)
        |> Queue.push_until_end(buf2, 10)

      # then
      refute queue.collectable?
      assert length(queue.target_samples) == 2
    end

    test "change to collectable state when audio track's duration is smaller than max duration but larger than target duration" do
      # given
      queue = empty_audio_queue(DurationRange.new(10, 20))
      refute queue.collectable?

      # when
      buffer = with_buffer(dts: 35, duration: 1)
      queue = Queue.push_until_end(queue, buffer, 10)

      # then
      assert queue.collectable?
    end

    test "change to collectable state when audio track's duration exceeds the max duration" do
      # given
      queue = empty_audio_queue(DurationRange.new(10, 20))
      refute queue.collectable?

      # when
      buf1 = with_buffer(dts: 25, duration: 1)
      buf2 = with_buffer(dts: 50, duration: 1)

      queue =
        queue
        |> Queue.push_until_end(buf1, 10)
        |> Queue.push_until_end(buf2, 10)

      # then
      assert queue.collectable?
      assert queue.target_samples == [buf1]
      assert queue.excess_samples == [buf2]

      {samples, queue} = Queue.collect(queue)
      refute queue.collectable?
      assert samples == [buf1]
      assert queue.target_samples == [buf2]
    end

    test "change to collectable state when video track's sample is a keyframe and track's duration exceeds either min or target duration" do
      # given
      queue = empty_video_queue(DurationRange.new(10, 20))
      refute queue.collectable?

      # when
      buf1 = with_keyframe_buffer(dts: 15, duration: 1, keyframe?: false)
      buf2 = with_keyframe_buffer(dts: 25, duration: 1, keyframe?: false)
      buf3 = with_keyframe_buffer(dts: 30, duration: 1, keyframe?: false)

      # dts > min and dts < mid
      key1 = with_keyframe_buffer(dts: 26, duration: 1, keyframe?: true)
      # dts > mid and dts < end
      key2 = with_keyframe_buffer(dts: 35, duration: 1, keyframe?: true)

      queue1 =
        queue
        |> Queue.push_until_end(buf1, 10)
        |> Queue.push_until_end(buf2, 10)
        |> Queue.push_until_end(key1, 10)

      queue2 =
        queue
        |> Queue.push_until_end(buf1, 10)
        |> Queue.push_until_end(buf2, 10)
        |> Queue.push_until_end(buf3, 10)
        |> Queue.push_until_end(key2, 10)

      # reference cachce that should not triggeer collection
      non_collectibe_queue =
        queue
        |> Queue.push_until_end(buf1, 10)
        |> Queue.push_until_end(buf2, 10)
        |> Queue.push_until_end(buf3, 10)

      # then
      refute non_collectibe_queue.collectable?
      assert queue1.collectable?
      assert queue2.collectable?

      assert queue1.target_samples == [buf1, buf2]
      assert queue2.target_samples == [buf1, buf2, buf3]

      assert queue1.excess_samples == [key1]
      assert queue2.excess_samples == [key2]
    end

    test "change to collectable state when video track's sample is not a keyframe but the track's duration exceeds the max duration" do
      # given
      queue = empty_video_queue(DurationRange.new(10, 20))
      refute queue.collectable?

      # when
      buf1 = with_keyframe_buffer(dts: 10, duration: 1, keyframe?: false)
      buf2 = with_keyframe_buffer(dts: 25, duration: 1, keyframe?: false)
      buf3 = with_keyframe_buffer(dts: 50, duration: 1, keyframe?: false)

      queue =
        queue
        |> Queue.push_until_end(buf1, 10)
        |> Queue.push_until_end(buf2, 10)
        |> Queue.push_until_end(buf3, 10)

      # then
      assert queue.collectable?

      {samples, queue} = Queue.collect(queue)

      refute queue.collectable?
      assert samples == [buf1, buf2]
      assert queue.target_samples == [buf3]
    end
  end
end
