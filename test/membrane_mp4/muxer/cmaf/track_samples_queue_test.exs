defmodule Membrane.MP4.Muxer.CMAF.TrackSamplesQueueTest do
  use ExUnit.Case, async: true

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

  defp empty_video_queue(), do: %Queue{track_with_keyframes?: true}
  defp empty_audio_queue(), do: %Queue{track_with_keyframes?: false}

  defp with_collectable(queue), do: %Queue{queue | collectable?: true}

  describe "Pushing to queue using push/3 should" do
    test "not change to collectable state when the sample's dts is lower than end timestamp" do
      # given
      audio_queue = empty_audio_queue()
      video_queue = empty_video_queue()
      refute audio_queue.collectable?
      refute video_queue.collectable?

      # when
      audio_buffer = with_buffer(dts: 5, duration: 10)
      video_buffer1 = with_keyframe_buffer(dts: 5, duration: 10, keyframe?: false)
      video_buffer2 = with_keyframe_buffer(dts: 6, duration: 10, keyframe?: true)

      audio_queue = Queue.push(audio_queue, audio_buffer, 10)

      video_queue =
        video_queue
        |> Queue.push(video_buffer1, 10)
        |> Queue.push(video_buffer2, 10)

      # then
      refute audio_queue.collectable?
      refute video_queue.collectable?
    end

    test "change to collectable state when sample's dts exceeds end timestamp" do
      # given
      audio_queue = empty_audio_queue()
      video_queue = empty_video_queue()
      refute audio_queue.collectable?
      refute video_queue.collectable?

      # when
      audio_buffer = with_buffer(dts: 20, duration: 10)
      video_buffer = with_keyframe_buffer(dts: 20, duration: 10, keyframe?: false)

      audio_queue = Queue.push(audio_queue, audio_buffer, 10)
      video_queue = Queue.push(video_queue, video_buffer, 10)

      # then
      assert audio_queue.collectable?
      assert video_queue.collectable?
    end

    test "keep collecting when sample's dts exceeds end timestamp" do
      # given
      queue = empty_video_queue()
      refute queue.collectable?

      # when
      buf1 = with_keyframe_buffer(dts: 30, duration: 10, keyframe?: false)
      buf2 = with_keyframe_buffer(dts: 40, duration: 10, keyframe?: false)

      queue =
        queue
        |> Queue.push(buf1, 10)
        |> Queue.push(buf2, 10)

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
      queue = Queue.push(queue, buffer, 10)

      # then
      assert queue.target_samples == []
      assert queue.excess_samples == [buffer]
    end

    test "keep accumulated duration of target samples" do
      # given
      queue = empty_audio_queue()
      assert queue.collected_duration == 0

      # when
      buf1 = with_buffer(dts: 10, duration: 10)
      buf2 = with_buffer(dts: 10, duration: 20)

      queue =
        queue
        |> Queue.push(buf1, 30)
        |> Queue.push(buf2, 30)

      # then
      assert queue.collected_duration == buf1.metadata.duration + buf2.metadata.duration
    end
  end

  describe "Pushing to queue using push/5 should" do
    test "result in a proper collection once in collectable state" do
      # given
      queue = empty_audio_queue()

      # when
      buf1 = with_buffer(dts: 10, duration: 10)
      # buf2 should cause the collection
      buf2 = with_buffer(dts: 30, duration: 20)

      queue =
        queue
        |> Queue.push(buf1, 20, 25)
        |> Queue.push(buf2, 20, 25)

      # then
      assert queue.collectable?

      {samples, queue} = Queue.collect(queue)

      assert samples == [buf1]
      refute queue.collectable?
      assert queue.target_samples == [buf2]
    end

    test "change to collectable state when video sample exceeds mid timestamp and is a keyframe" do
      # given
      queue = empty_video_queue()
      refute queue.collectable?

      # when
      buffer = with_keyframe_buffer(dts: 30, duration: 10, keyframe?: true)
      queue = Queue.push(queue, buffer, 10, 15, 30)

      # then
      assert queue.collectable?
    end

    test "not change to collectable state when audio sample's dts is lower than minimum and mid timestamps" do
      # given
      queue = empty_audio_queue()
      refute queue.collectable?

      # when
      buf1 = with_buffer(dts: 15, duration: 10)
      buf2 = with_buffer(dts: 25, duration: 10)

      queue =
        queue
        |> Queue.push(buf1, 20, 30, 40)
        |> Queue.push(buf2, 20, 30, 40)

      # then
      refute queue.collectable?
      assert length(queue.target_samples) == 2
    end

    test "change to collectable state when audio sample's is lower than end timestamp but higher than mid timestamp" do
      # given
      queue = empty_audio_queue()
      refute queue.collectable?

      # when
      buffer = with_buffer(dts: 35, duration: 10)
      queue = Queue.push(queue, buffer, 20, 30, 40)

      # then
      assert queue.collectable?
    end

    test "change to collectable state when audio sample's dts exceedes end timestamp" do
      # given
      queue = empty_audio_queue()
      refute queue.collectable?

      # when
      buf1 = with_buffer(dts: 25, duration: 10)
      buf2 = with_buffer(dts: 50, duration: 10)

      queue =
        queue
        |> Queue.push(buf1, 20, 30, 40)
        |> Queue.push(buf2, 20, 30, 40)

      # then
      assert queue.collectable?
      assert queue.target_samples == [buf1]
      assert queue.excess_samples == [buf2]

      {samples, queue} = Queue.collect(queue)
      refute queue.collectable?
      assert samples == [buf1]
      assert queue.target_samples == [buf2]
    end

    test "change to collectable state when video sample is a keyframe and its dts exceeds either min or mid timestamp" do
      # given
      queue = empty_video_queue()
      refute queue.collectable?

      # when
      buf1 = with_keyframe_buffer(dts: 15, duration: 10, keyframe?: false)
      buf2 = with_keyframe_buffer(dts: 25, duration: 10, keyframe?: false)
      buf3 = with_keyframe_buffer(dts: 30, duration: 10, keyframe?: false)

      # dts > min and dts < mid
      key1 = with_keyframe_buffer(dts: 26, duration: 10, keyframe?: true)
      # dts > mid and dts < end
      key2 = with_keyframe_buffer(dts: 35, duration: 10, keyframe?: true)

      queue1 =
        queue
        |> Queue.push(buf1, 20, 30, 40)
        |> Queue.push(buf2, 20, 30, 40)
        |> Queue.push(key1, 20, 30, 40)

      queue2 =
        queue
        |> Queue.push(buf1, 20, 30, 40)
        |> Queue.push(buf2, 20, 30, 40)
        |> Queue.push(buf3, 20, 30, 40)
        |> Queue.push(key2, 20, 30, 40)

      # reference cachce that should not triggeer collection
      non_collectibe_queue =
        queue
        |> Queue.push(buf1, 20, 30, 40)
        |> Queue.push(buf2, 20, 30, 40)
        |> Queue.push(buf3, 20, 30, 40)

      # then
      refute non_collectibe_queue.collectable?
      assert queue1.collectable?
      assert queue2.collectable?

      assert queue1.target_samples == [buf1, buf2]
      assert queue2.target_samples == [buf1, buf2, buf3]

      assert queue1.excess_samples == [key1]
      assert queue2.excess_samples == [key2]
    end

    test "change to collectable state when video sample's dts is not a keyframe but exceeds end timestamp" do
      # given
      queue = empty_video_queue()
      refute queue.collectable?

      # when
      buf1 = with_keyframe_buffer(dts: 10, duration: 10, keyframe?: false)
      buf2 = with_keyframe_buffer(dts: 25, duration: 10, keyframe?: false)
      buf3 = with_keyframe_buffer(dts: 50, duration: 10, keyframe?: false)

      queue =
        queue
        |> Queue.push(buf1, 20, 30, 40)
        |> Queue.push(buf2, 20, 30, 40)
        |> Queue.push(buf3, 20, 30, 40)

      # then
      assert queue.collectable?

      {samples, queue} = Queue.collect(queue)

      refute queue.collectable?
      assert samples == [buf1, buf2]
      assert queue.target_samples == [buf3]
    end
  end
end
