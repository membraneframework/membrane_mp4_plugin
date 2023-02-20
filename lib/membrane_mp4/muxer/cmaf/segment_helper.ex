defmodule Membrane.MP4.Muxer.CMAF.SegmentHelper do
  @moduledoc false

  use Bunch

  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: SamplesQueue

  @type pad_t :: Membrane.Pad.ref_t()
  @type state_t :: map()

  @type segment_t :: %{
          pad_t() => [Membrane.Buffer.t()]
        }

  @spec push_segment(state_t(), Membrane.Pad.ref_t(), Membrane.Buffer.t()) ::
          {:no_segment, state_t()} | {:segment, segment_t(), state_t()}
  def push_segment(state, pad, sample) do
    queue = Map.fetch!(state.sample_queues, pad)
    is_video = queue.track_with_keyframes?

    if is_video do
      push_video_segment(state, queue, pad, sample)
    else
      push_audio_segment(state, queue, pad, sample)
    end
  end

  defp push_video_segment(state, queue, pad, sample) do
    base_timestamp = max_segment_base_timestamp(state)

    queue = SamplesQueue.push_until_target(queue, sample, base_timestamp)

    if queue.collectable? do
      collect_samples_for_video_track(pad, queue, state)
    else
      {:no_segment, update_queue_for(pad, queue, state)}
    end
  end

  defp push_audio_segment(state, queue, pad, sample) do
    base_timestamp = max_segment_base_timestamp(state)

    any_video_tracks? =
      Enum.any?(state.sample_queues, fn {_pad, queue} -> queue.track_with_keyframes? end)

    queue =
      if any_video_tracks? do
        SamplesQueue.force_push(queue, sample)
      else
        SamplesQueue.plain_push_until_target(queue, sample, base_timestamp)
      end

    if queue.collectable? do
      collect_samples_for_audio_track(pad, queue, state)
    else
      {:no_segment, update_queue_for(pad, queue, state)}
    end
  end

  @spec push_partial_segment(state_t(), Membrane.Pad.ref_t(), Membrane.Buffer.t()) ::
          {:no_segment, state_t()} | {:segment, segment_t(), state_t()}
  def push_partial_segment(state, pad, sample) do
    queue = Map.fetch!(state.sample_queues, pad)

    if queue.track_with_keyframes? do
      push_partial_video_segment(state, queue, pad, sample)
    else
      push_partial_audio_segment(state, queue, pad, sample)
    end
  end

  defp push_partial_video_segment(state, queue, pad, sample) do
    collected_duration = queue.collected_samples_duration

    total_collected_durations =
      Map.fetch!(state.pad_to_track_data, pad).parts_duration + collected_duration

    base_timestamp = max_segment_base_timestamp(state)

    queue =
      if total_collected_durations < state.segment_duration_range.min do
        SamplesQueue.plain_push_until_target(queue, sample, base_timestamp)
      else
        SamplesQueue.push_until_end(queue, sample, base_timestamp)
      end

    if queue.collectable? do
      pad
      |> collect_samples_for_video_track(queue, state)
      |> maybe_reset_partial_durations()
    else
      {:no_segment, update_queue_for(pad, queue, state)}
    end
  end

  @spec take_all_samples(state_t()) :: {:segment, segment_t(), state_t()}
  def take_all_samples(state) do
    do_take_sample(state, &SamplesQueue.drain_samples/1)
  end

  @spec take_all_samples_for(state_t(), Membrane.Time.t()) :: {:segment, segment_t(), state_t()}
  def take_all_samples_for(state, duration) do
    end_timestamp = max_segment_base_timestamp(state) + duration

    do_take_sample(state, &SamplesQueue.force_collect(&1, end_timestamp))
  end

  defp do_take_sample(state, collect_fun) do
    {segment, state} =
      state.sample_queues
      |> Enum.reject(fn {_pad, queue} -> SamplesQueue.empty?(queue) end)
      |> Enum.map_reduce(state, fn {pad, queue}, state ->
        {samples, queue} = collect_fun.(queue)

        {{pad, samples}, update_queue_for(pad, queue, state)}
      end)

    segment
    |> Map.new()
    |> maybe_return_segment(state)
    |> maybe_reset_partial_durations()
  end

  defp push_partial_audio_segment(state, queue, pad, sample) do
    any_video_tracks? =
      Enum.any?(state.sample_queues, fn {_pad, queue} -> queue.track_with_keyframes? end)

    # if we have any video track then let the video track decide when to collect audio tracks
    if any_video_tracks? do
      queue = SamplesQueue.force_push(queue, sample)

      {:no_segment, update_queue_for(pad, queue, state)}
    else
      base_timestamp = max_segment_base_timestamp(state)

      queue = SamplesQueue.plain_push_until_target(queue, sample, base_timestamp)

      if queue.collectable? do
        pad
        |> collect_samples_for_audio_track(queue, state)
        |> maybe_reset_partial_durations()
      else
        {:no_segment, update_queue_for(pad, queue, state)}
      end
    end
  end

  defp update_queue_for(pad, queue, state), do: put_in(state, [:sample_queues, pad], queue)

  defp collect_samples_for_video_track(pad, queue, state) do
    end_timestamp = SamplesQueue.last_collected_dts(queue)

    {collected, queue} = SamplesQueue.collect(queue)

    state = update_queue_for(pad, queue, state)

    if tracks_ready_for_collection?(state, end_timestamp) do
      state = update_partial_duration(state, pad, collected)

      {segment, state} =
        state.sample_queues
        |> Map.delete(pad)
        |> collect_segment_from_queue(end_timestamp, state)

      segment = Map.put(segment, pad, collected)

      maybe_return_segment(segment, state)
    else
      {:no_segment, update_queue_for(pad, queue, state)}
    end
  end

  defp collect_samples_for_audio_track(pad, queue, state) do
    end_timestamp = SamplesQueue.last_collected_dts(queue)
    state = update_queue_for(pad, queue, state)

    if tracks_ready_for_collection?(state, end_timestamp) do
      {segment, state} = collect_segment_from_queue(state.sample_queues, end_timestamp, state)

      maybe_return_segment(segment, state)
    else
      {:no_segment, state}
    end
  end

  defp collect_segment_from_queue(queue_per_pad, end_timestamp, state) do
    Enum.reduce(queue_per_pad, {%{}, state}, fn {pad, queue}, {acc, state} ->
      {collected, queue} = SamplesQueue.force_collect(queue, end_timestamp)

      state =
        pad
        |> update_queue_for(queue, state)
        |> update_partial_duration(pad, collected)

      {Map.put(acc, pad, collected), update_queue_for(pad, queue, state)}
    end)
  end

  defp tracks_ready_for_collection?(state, end_timestamp) do
    Enum.all?(state.sample_queues, fn {_pad, queue} ->
      SamplesQueue.last_collected_dts(queue) >= end_timestamp
    end)
  end

  defp update_partial_duration(state, pad, samples) do
    duration = Enum.reduce(samples, 0, &(&1.metadata.duration + &2))

    update_in(state, [:pad_to_track_data, pad, :parts_duration], &(&1 + duration))
  end

  defp maybe_return_segment(segment, state) do
    if Enum.any?(segment, fn {_pad, samples} -> not Enum.empty?(samples) end) do
      {:segment, segment, state}
    else
      {:no_segment, state}
    end
  end

  defp maybe_reset_partial_durations({:no_segment, _state} = result), do: result

  defp maybe_reset_partial_durations({:segment, segment, state}) do
    min_duration = state.segment_duration_range.min

    independent? = Enum.all?(segment, fn {_pad, samples} -> starts_with_keyframe?(samples) end)

    enough_duration? =
      Enum.all?(state.pad_to_track_data, fn {pad, data} ->
        data.parts_duration >= min_duration and not (Map.get(segment, pad, []) |> Enum.empty?())
      end)

    if independent? and enough_duration? do
      maybe_return_segment(segment, reset_partial_durations(state))
    else
      maybe_return_segment(segment, state)
    end
  end

  defp max_segment_base_timestamp(state) do
    state.pad_to_track_data
    |> Enum.reject(fn {_key, track_data} -> is_nil(track_data.segment_base_timestamp) end)
    |> Enum.map(fn {_key, track_data} ->
      Ratio.to_float(track_data.segment_base_timestamp)
    end)
    |> Enum.max()
  end

  defp reset_partial_durations(state) do
    state
    |> Map.update!(:pad_to_track_data, fn entries ->
      entries
      |> Map.new(fn {pad, data} -> {pad, Map.replace(data, :parts_duration, 0)} end)
    end)
  end

  @compile {:inline, is_key_frame: 1}
  defp is_key_frame(%{metadata: metadata}),
    do: Map.get(metadata, :mp4_payload, %{}) |> Map.get(:key_frame?, true)

  defp starts_with_keyframe?([]), do: false

  defp starts_with_keyframe?([target | _rest]),
    do: is_key_frame(target)
end
