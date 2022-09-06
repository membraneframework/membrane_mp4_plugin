defmodule Membrane.MP4.Muxer.CMAF.Segment.HelperTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.MP4.Muxer.CMAF.Segment.Helper, as: SegmentHelper

  test "get_discontinuity_segment works correctly" do
    muxer_partial_state = %{
      awaiting_caps: nil,
      pad_to_track_data: %{
        a: %{elapsed_time: 0}
      },
      samples: %{
        # samples are reversed for performance reasons, but it's not very intuitive
        a:
          Enum.reverse([
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
          ])
      }
    }

    assert {:ok, _segment, new_state} =
             SegmentHelper.get_discontinuity_segment(muxer_partial_state, 10)

    Enum.each(new_state.samples, fn {_key, buffers} ->
      # verify that each tracks now starts with the keyframe
      assert List.last(buffers).metadata.mp4_payload.key_frame?
    end)
  end
end
