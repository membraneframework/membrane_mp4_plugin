defmodule Membrane.MP4.Muxer.CMAF.Segment.Helper do
  @moduledoc false

  use Bunch

  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: SamplesQueue

  @type pad_t :: Membrane.Pad.ref_t()
  @type state_t :: map()

  @type segment_t :: %{
          pad_t() => [Membrane.Buffer.t()]
        }

  @spec push_segment(state_t(), Membrane.Pad.ref_t(), Membrane.Buffer.t()) ::
          {:ok, state_t()} | {:ok, segment_t(), state_t()}
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
    duration_range = state.segment_duration_range
    end_timestamp = max_end_timestamp(state) + duration_range.min

    queue = SamplesQueue.push(queue, sample, end_timestamp)

    if queue.collectable? do
      collect_samples_for_video_track(pad, queue, state)
    else
      {:ok, update_queue_for(pad, queue, state)}
    end
  end

  defp push_audio_segment(state, queue, pad, sample) do
    duration_range = state.segment_duration_range
    end_timestamp = max_end_timestamp(state) + duration_range.min

    any_video_tracks? =
      Enum.any?(state.sample_queues, fn {_pad, queue} -> queue.track_with_keyframes? end)

    queue =
      if any_video_tracks? do
        SamplesQueue.force_push(queue, sample)
      else
        SamplesQueue.push(queue, sample, end_timestamp)
      end

    if queue.collectable? do
      collect_samples_for_audio_track(pad, queue, state)
    else
      {:ok, update_queue_for(pad, queue, state)}
    end
  end

  @spec push_partial_segment(state_t(), Membrane.Pad.ref_t(), Membrane.Buffer.t()) ::
          {:ok, state_t()} | {:ok, segment_t(), state_t()}
  def push_partial_segment(state, pad, sample) do
    queue = Map.fetch!(state.sample_queues, pad)

    if queue.track_with_keyframes? do
      push_partial_video_segment(state, queue, pad, sample)
    else
      push_partial_audio_segment(state, queue, pad, sample)
    end
  end

  defp push_partial_video_segment(state, queue, pad, sample) do
    %{
      partial_segment_duration_range: part_duration_range,
      segment_duration_range: duration_range
    } = state

    collected_duration = queue.collected_duration

    total_collected_durations =
      Map.fetch!(state.pad_to_track_data, pad).parts_duration + collected_duration

    base_timestamp = max_end_timestamp(state)

    queue =
      if total_collected_durations < duration_range.min do
        SamplesQueue.push_part(queue, sample, base_timestamp + part_duration_range.target)
      else
        min_timestamp = base_timestamp + part_duration_range.min
        mid_timestamp = base_timestamp + part_duration_range.target
        max_timestamp = base_timestamp + part_duration_range.min + part_duration_range.target

        SamplesQueue.push_part(queue, sample, min_timestamp, mid_timestamp, max_timestamp)
      end

    if queue.collectable? do
      pad
      |> collect_samples_for_video_track(queue, state)
      |> maybe_reset_partial_durations()
    else
      {:ok, update_queue_for(pad, queue, state)}
    end
  end

  @spec take_all_samples(state_t()) :: {:ok, segment_t(), state_t()}
  def take_all_samples(state) do
    segment =
      state.sample_queues
      |> Enum.reject(fn {_pad, queue} -> SamplesQueue.empty?(queue) end)
      |> Enum.map(fn {pad, queue} ->
        {samples, _queue} = SamplesQueue.drain_samples(queue)

        {pad, samples}
      end)
      |> Map.new()

    {:ok, segment, state}
  end

  @spec take_all_samples_for(state_t(), Membrane.Time.t()) :: {:ok, segment_t(), state_t()}
  def take_all_samples_for(state, duration) do
    end_timestamp = max_end_timestamp(state) + duration

    {segment, state} =
      state.sample_queues
      |> Enum.reject(fn {_pad, queue} -> SamplesQueue.empty?(queue) end)
      |> Enum.map_reduce(state, fn {pad, queue}, state ->
        {samples, queue} = SamplesQueue.force_collect(queue, end_timestamp)

        {{pad, samples}, update_queue_for(pad, queue, state)}
      end)

    maybe_reset_partial_durations({:ok, Map.new(segment), state})
  end

  defp push_partial_audio_segment(state, queue, pad, sample) do
    %{
      partial_segment_duration_range: part_duration_range,
      segment_duration_range: duration_range
    } = state

    any_video_tracks? =
      Enum.any?(state.sample_queues, fn {_pad, queue} -> queue.track_with_keyframes? end)

    # if we have any video track then let the video track decide when to collect audio tracks
    if any_video_tracks? do
      queue = SamplesQueue.force_push(queue, sample)

      {:ok, update_queue_for(pad, queue, state)}
    else
      parts_duration = parts_duration_for(pad, state)

      base_timestamp = max_end_timestamp(state)

      duration =
        min(
          part_duration_range.target,
          max(part_duration_range.min, duration_range.target - parts_duration)
        )

      queue = SamplesQueue.push_part(queue, sample, base_timestamp + duration)

      if queue.collectable? do
        pad
        |> collect_samples_for_audio_track(queue, state)
        |> maybe_reset_partial_durations()
      else
        {:ok, update_queue_for(pad, queue, state)}
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

      {:ok, segment, state}
    else
      {:ok, update_queue_for(pad, queue, state)}
    end
  end

  defp collect_samples_for_audio_track(pad, queue, state) do
    end_timestamp = SamplesQueue.last_collected_dts(queue)
    state = update_queue_for(pad, queue, state)

    if tracks_ready_for_collection?(state, end_timestamp) do
      {segment, state} = collect_segment_from_queue(state.sample_queues, end_timestamp, state)

      {:ok, segment, state}
    else
      {:ok, state}
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

  defp maybe_reset_partial_durations({:ok, _state} = result), do: result

  defp maybe_reset_partial_durations({:ok, segment, state}) do
    min_duration = state.segment_duration_range.min

    independent? = Enum.all?(segment, fn {_pad, samples} -> starts_with_keyframe?(samples) end)

    enough_duration? =
      Enum.all?(state.pad_to_track_data, fn {pad, data} ->
        data.parts_duration >= min_duration and not (Map.get(segment, pad, []) |> Enum.empty?())
      end)

    if independent? and enough_duration? do
      {:ok, segment, reset_partial_durations(state)}
    else
      {:ok, segment, state}
    end
  end

  defp max_end_timestamp(state) do
    Enum.map(state.pad_to_track_data, fn {_key, track_data} ->
      Ratio.to_float(track_data.elapsed_time)
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

  @compile {:inline, parts_duration_for: 2}
  defp parts_duration_for(pad, state) do
    Map.fetch!(state.pad_to_track_data, pad).parts_duration
  end

  @compile {:inline, is_key_frame: 1}
  defp is_key_frame(%{metadata: metadata}),
    do: Map.get(metadata, :mp4_payload, %{}) |> Map.get(:key_frame?, true)

  defp starts_with_keyframe?([]), do: false

  defp starts_with_keyframe?([target | _rest]),
    do: is_key_frame(target)
end
