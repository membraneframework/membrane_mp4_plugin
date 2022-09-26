defmodule Membrane.MP4.Muxer.CMAF.Segment.HelperTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.MP4.Muxer.CMAF.Segment.Helper, as: SegmentHelper
  alias Membrane.MP4.Muxer.CMAF.SegmentDurationRange
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: Queue

  test "get_discontinuity_segment works correctly" do
    queue = %Queue{track_with_keyframes?: true}

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

    queue = Enum.reduce(buffers, queue, &Queue.force_push(&2, &1))

    state = %{
      awaiting_caps: nil,
      segment_duration_range: SegmentDurationRange.new(100),
      pad_to_track_data: %{
        a: %{elapsed_time: 0, parts_duration: 0}
      },
      sample_queues: %{a: queue}
    }

    assert {:segment, _segment, state} = SegmentHelper.take_all_samples_for(state, 10)

    Enum.each(state.sample_queues, fn {_key, queue} ->
      # verify that each tracks now starts with the keyframe
      {buffers, _queue} = Queue.drain_samples(queue)
      assert hd(buffers).metadata.mp4_payload.key_frame?
    end)
  end
end
