defmodule Membrane.MP4.Muxer.CMAF.TrackSamplesCacheTest do
  use ExUnit.Case, async: true

  alias Membrane.MP4.Muxer.CMAF.TrackSamplesCache, as: Cache

  defp ms(time) do
    Membrane.Time.milliseconds(time)
  end

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

  defp empty_video_cache(), do: %Cache{supports_keyframes?: true}
  defp empty_audio_cache(), do: %Cache{supports_keyframes?: false}

  defp with_collected_state(cache), do: %Cache{cache | state: :to_collect}

  defp collecting?(%Cache{state: :collecting}), do: true
  defp collecting?(%Cache{state: :to_collect}), do: false

  describe "Regular push to cache should" do
    test "not change state when the sample's dts is lower than end timestamp" do
      # given
      cache = empty_video_cache()
      assert collecting?(cache)

      # when
      buffer = with_buffer(dts: 10, duration: 10)
      cache = Cache.push(cache, buffer, 20)

      # then
      assert collecting?(cache)
    end

    test "change to collected state when audio sample exceeds end timestamp" do
      # given
      cache = empty_audio_cache()
      assert collecting?(cache)

      # when
      buffer = with_buffer(dts: 20, duration: 10)
      cache = Cache.push(cache, buffer, 10)

      # then
      refute collecting?(cache)
    end

    test "keep collecting when video exceeds end timestamp but is not a keyframe" do
      # given
      cache = empty_video_cache()
      assert collecting?(cache)

      # when
      buffer = with_keyframe_buffer(dts: 20, duration: 10, keyframe?: false)
      cache = Cache.push(cache, buffer, 10)

      # then
      assert collecting?(cache)
    end

    test "change to collected state when video sample exceeds end timestamp and is a keyframe" do
      # given
      cache = empty_video_cache()
      assert collecting?(cache)

      # when
      buffer = with_keyframe_buffer(dts: 20, duration: 10, keyframe?: true)
      cache = Cache.push(cache, buffer, 10)

      # then
      refute collecting?(cache)
    end

    test "put samples in 'to_collect' group when cache is already ready for collection" do
      # given
      cache = empty_audio_cache() |> with_collected_state()
      assert cache.collected == []

      # when
      buffer = with_buffer(dts: 20, duration: 10)
      cache = Cache.push(cache, buffer, 10)

      # then
      assert cache.collected == []
      assert cache.to_collect == [buffer]
    end

    test "keep accumulated samples' duration" do
      # given
      cache = empty_audio_cache()
      assert cache.collected_duration == 0

      # when
      buf1 = with_buffer(dts: 10, duration: 10)
      buf2 = with_buffer(dts: 10, duration: 20)

      cache =
        cache
        |> Cache.push(buf1, 30)
        |> Cache.push(buf2, 30)

      # then
      assert cache.collected_duration == buf1.metadata.duration + buf2.metadata.duration
    end

    test "result in a proper collection once in 'to_collect' state" do
      # given
      cache = empty_audio_cache()

      # when
      buf1 = with_buffer(dts: 10, duration: 10)
      # buf2 should cause the collection
      buf2 = with_buffer(dts: 30, duration: 20)

      cache =
        cache
        |> Cache.push(buf1, 20)
        |> Cache.push(buf2, 20)

      # then
      refute collecting?(cache)

      {samples, cache} = Cache.collect(cache)

      assert samples == [buf1]
      assert collecting?(cache)
      assert cache.collected == [buf2]
    end
  end

  describe "Partial push to cache should" do
    test "not change collecting state when audio sample's dts is lower than minimum and mid timestamps" do
      # given
      cache = empty_audio_cache()
      assert collecting?(cache)

      # when
      buf1 = with_buffer(dts: 15, duration: 10)
      buf2 = with_buffer(dts: 25, duration: 10)

      cache =
        cache
        |> Cache.push_part(buf1, 20, 30, 40)
        |> Cache.push_part(buf2, 20, 30, 40)

      # then
      assert collecting?(cache)
      assert length(cache.collected) == 2
    end

    test "not change collecting state when audio sample's is lower than end timestamp but should put in 'to_collect' gropu" do
      # given
      cache = empty_audio_cache()
      assert collecting?(cache)

      # when
      buffer = with_buffer(dts: 35, duration: 10)
      cache = Cache.push_part(cache, buffer, 20, 30, 40)

      # then
      assert collecting?(cache)
      assert cache.collected == []
      assert cache.to_collect == [buffer]
    end

    test "change to to_collect state when audio sample's dts exceedes end timestamp" do
      # given
      cache = empty_audio_cache()
      assert collecting?(cache)

      # when
      buf1 = with_buffer(dts: 25, duration: 10)
      buf2 = with_buffer(dts: 50, duration: 10)

      cache =
        cache
        |> Cache.push_part(buf1, 20, 30, 40)
        |> Cache.push_part(buf2, 20, 30, 40)

      # then
      refute collecting?(cache)
      assert cache.collected == [buf1]
      assert cache.to_collect == [buf2]

      {samples, cache} = Cache.collect(cache)
      assert collecting?(cache)
      assert samples == [buf1]
      assert cache.collected == [buf2]
    end

    # NOTE: to delete
    # test "not change collecting state when sample's dts is lower than minimum timestamp" do
    #   # given
    #   video_cache = empty_audio_cache()
    #   assert collecting?(video_cache)
    #
    #   # when
    #   buf1 = with_buffer(dts: 10, duration: 10)
    #   buf2 = with_keyframe_buffer(dts: 10, duration: 10, keyframe?: false)
    #   # even buffer with a keyframe should not make the cache collectible
    #   buf2 = with_keyframe_buffer(dts: 15, duration: 10, keyframe?: true)
    #
    #   audio_cache = Cache.push_part(audio_cache, buf1, 20, 30, 40)
    #   video_cache = 
    #     video_cache
    #     |> Cache.push_part(buf2, 20, 30, 40)
    #     |> Cache.push_part(buf3, 20, 30, 40)
    #
    #   # then
    #   assert collecting?(audio_cache)
    #   assert collecting?(video_cache)
    # end
  end
end