defmodule Membrane.MP4.Muxer.CMAF.Segment.HelperTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.MP4.Muxer.CMAF.Segment.Helper, as: SegmentHelper
  alias Membrane.MP4.Muxer.CMAF.SegmentDurationRange
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesCache, as: Cache

  test "get_discontinuity_segment works correctly" do
    cache = %Cache{supports_keyframes?: true}

    buffers = [
      %Buffer{
        payload: "a",
        dts: 0,
        pts: 0,
        metadata: %{duration: 10, mp4_payload: %{key_frame?: false}}
      },
      %Buffer{
        payload: "b",
        dts: 10,
        pts: 10,
        metadata: %{duration: 10, mp4_payload: %{key_frame?: true}}
      },
      %Buffer{
        payload: "c",
        dts: 20,
        pts: 20,
        metadata: %{duration: 10, mp4_payload: %{key_frame?: false}}
      }
    ]

    cache = Enum.reduce(buffers, cache, &Cache.force_push(&2, &1))

    state = %{
      awaiting_caps: nil,
      segment_duration_range: SegmentDurationRange.new(100),
      pad_to_track_data: %{
        a: %{elapsed_time: 0, parts_duration: 0}
      },
      samples_cache: %{a: cache}
    }

    assert {:ok, _segment, state} = SegmentHelper.take_all_samples_for(state, 10)

    Enum.each(state.samples_cache, fn {_key, cache} ->
      # verify that each tracks now starts with the keyframe
      {buffers, _cache} = Cache.drain_samples(cache)
      assert hd(buffers).metadata.mp4_payload.key_frame?
    end)
  end
end
