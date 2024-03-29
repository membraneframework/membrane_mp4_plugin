defmodule Membrane.MP4.Muxer.CMAF.SegmentHelperTest do
  use ExUnit.Case, async: true

  alias Membrane.MP4.Muxer.CMAF.DurationRange
  alias Membrane.MP4.Muxer.CMAF.SegmentHelper
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: Queue

  setup do
    chunk_duration_range = DurationRange.new(1, 50)

    state = %{
      awaiting_stream_formats: %{},
      segment_min_duration: 100,
      chunk_duration_range: chunk_duration_range,
      finish_current_segment?: false,
      input_to_output_pad: %{audio: :output, video: :output},
      input_groups: %{output: [:audio, :video]},
      pad_to_track_data: %{
        audio: %{
          segment_decoding_timestamp: 0,
          segment_presentation_timestamp: 0,
          chunks_duration: 0,
          buffer_awaiting_duration: nil
        },
        video: %{
          segment_decoding_timestamp: 0,
          segment_presentation_timestamp: 0,
          chunks_duration: 0,
          buffer_awaiting_duration: nil
        }
      },
      sample_queues: %{
        audio: %Queue{track_with_keyframes?: false, duration_range: chunk_duration_range},
        video: %Queue{track_with_keyframes?: true, duration_range: chunk_duration_range}
      }
    }

    [state: state]
  end

  defp push_buffer(pad, buffer, state) do
    case get_next_buffer(pad, buffer, state) do
      {nil, state} ->
        {:no_segment, state}

      {buffer, state} ->
        SegmentHelper.push_chunk(state, pad, buffer)
    end
  end

  defp push_n_buffers(type, range, state) do
    for i <- range, reduce: state do
      state ->
        {:no_segment, state} = push_buffer(type, buffer_with_timestamp(type, i), state)

        state
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
  test "new stream format forces segment collection", %{state: state} do
    # push first couple of video and audio samples
    state =
      for {type, amount} <- [video: 10, audio: 20], reduce: state do
        state ->
          push_n_buffers(type, 1..amount, state)
      end

    state = SegmentHelper.put_awaiting_stream_format(:video, @stream_format, state)

    # push couple of audio samples after new video stream format
    state = push_n_buffers(:audio, 21..30, state)

    state = SegmentHelper.update_awaiting_stream_format(state, :video)

    # prepare a keyframe
    keyframe_sample =
      :video
      |> buffer_with_timestamp(11)
      |> set_key_frame()

    # get last sample before the keyframe
    {sample, state} = get_next_buffer(:video, keyframe_sample, state)
    assert sample.dts == 10

    assert {[stream_format: {:output, @stream_format}], {:segment, segment, state}} =
             SegmentHelper.collect_segment_samples(state, :video, sample)

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
