defmodule Membrane.MP4.Muxer.CMAF.Segment.HelperTest do
  use ExUnit.Case, async: true

  alias Membrane.MP4.Muxer.CMAF
  alias Membrane.MP4.Muxer.CMAF.SegmentDurationRange
  alias Membrane.MP4.Muxer.CMAF.SegmentHelper
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: Queue

  setup do
    part_duration_range = SegmentDurationRange.new(1, 50)

    state = %{
      awaiting_stream_format: nil,
      segment_duration_range: SegmentDurationRange.new(1000),
      partial_segment_duration_range: part_duration_range,
      pad_to_track_data: %{
        audio: %{segment_base_timestamp: 0, parts_duration: 0, buffer_awaiting_duration: nil},
        video: %{segment_base_timestamp: 0, parts_duration: 0, buffer_awaiting_duration: nil}
      },
      sample_queues: %{
        audio: %Queue{track_with_keyframes?: false, duration_range: part_duration_range},
        video: %Queue{track_with_keyframes?: true, duration_range: part_duration_range}
      }
    }

    [state: state]
  end

  defp push_buffer(pad, buffer, state) do
    case get_next_buffer(pad, buffer, state) do
      {nil, state} ->
        {:no_segment, state}

      {buffer, state} ->
        SegmentHelper.push_partial_segment(state, pad, buffer)
    end
  end

  defp get_next_buffer(pad, buffer, state) do
    awaiting = state.pad_to_track_data[pad].buffer_awaiting_duration

    if awaiting do
      duration = buffer.dts - awaiting.dts

      awaiting = %Membrane.Buffer{
        awaiting
        | metadata: Map.put(awaiting.metadata, :duration, duration)
      }

      state = put_in(state, [:pad_to_track_data, pad, :buffer_awaiting_duration], buffer)

      {awaiting, state}
    else
      {nil, put_in(state, [:pad_to_track_data, pad, :buffer_awaiting_duration], buffer)}
    end
  end

  defp buffer_with_timestamp(pad, dts, pts \\ nil)

  defp buffer_with_timestamp(:audio, dts, pts) do
    %Membrane.Buffer{payload: <<>>, dts: dts, pts: pts || dts}
  end

  defp buffer_with_timestamp(:video, dts, pts) do
    %Membrane.Buffer{
      payload: <<>>,
      dts: dts,
      pts: pts || dts,
      metadata: %{h264: %{key_frame?: false}}
    }
  end

  defp set_key_frame(%Membrane.Buffer{metadata: %{h264: %{key_frame?: false}}} = buffer) do
    %{buffer | metadata: %{h264: %{key_frame?: true}}}
  end

  @stream_format :stream_format
  test "get_discontinuity_segment works correctly", %{state: state} do
    # push first couple of video samples
    state =
      for i <- 1..10, reduce: state do
        state ->
          {:no_segment, state} = push_buffer(:video, buffer_with_timestamp(:video, i), state)

          state
      end

    # push first couple of audio samples
    state =
      for i <- 1..20, reduce: state do
        state ->
          {:no_segment, state} = push_buffer(:audio, buffer_with_timestamp(:audio, i), state)

          state
      end

    state = CMAF.put_awaiting_stream_format(:video, @stream_format, state)

    # push couple of audio samples after new video stream format
    state =
      for i <- 21..30, reduce: state do
        state ->
          {:no_segment, state} = push_buffer(:audio, buffer_with_timestamp(:audio, i), state)

          state
      end

    state = CMAF.update_awaiting_stream_format(state, :video)

    # prepare a keyframe
    keyframe_sample =
      :video
      |> buffer_with_timestamp(11)
      |> set_key_frame()

    # get last sample before the keyframe
    {sample, state} = get_next_buffer(:video, keyframe_sample, state)
    assert sample.dts == 10

    assert {[stream_format: {:output, @stream_format}], {:segment, segment, state}} =
             CMAF.collect_segment_samples(state, :video, sample)

    assert %{
             audio: audio_buffers,
             video: video_buffers
           } = segment

    assert Enum.count(audio_buffers) == 10
    assert Enum.count(video_buffers) == 10

    assert %Queue{target_samples: [], excess_samples: []} = state.sample_queues.video

    # make sure that collecting the video segments does not affect collected audio
    assert %Queue{target_samples: target_audio_samples, excess_samples: []} =
             state.sample_queues.audio

    # 19 instead of 20 as the last buffer is still awaiting duration
    assert Enum.count(target_audio_samples) == 19
  end
end
