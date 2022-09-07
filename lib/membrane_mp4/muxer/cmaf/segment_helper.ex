defmodule Membrane.MP4.Muxer.CMAF.Segment.Helper do
  @moduledoc false

  use Bunch

  alias Membrane.MP4.Muxer.CMAF.TrackSamplesCache, as: Cache

  @type pad_t :: Membrane.Pad.ref_t()
  @type state_t :: map()

  @type segment_t :: %{
          pad_t() => [Membrane.Buffer.t()]
        }

  @spec push_segment(state_t(), Membrane.Pad.ref_t(), Membrane.Buffer.t()) ::
          {:ok, state_t()} | {:ok, segment_t(), state_t()}
  def push_segment(state, pad, sample) do
    cache = Map.fetch!(state.samples_cache, pad)
    is_video = cache.supports_keyframes?

    if is_video do
      push_video_segment(state, cache, pad, sample)
    else
      push_audio_segment(state, cache, pad, sample)
    end
  end

  defp push_video_segment(state, cache, pad, sample) do
    duration_range = state.segment_duration_range
    end_timestamp = max_end_timestamp(state) + duration_range.min

    case Cache.push(cache, sample, end_timestamp) do
      %Cache{state: :collecting} = cache ->
        {:ok, update_cache_for(pad, cache, state)}

      %Cache{state: :to_collect} = cache ->
        collect_samples_for_video_track(pad, cache, state)
    end
  end

  defp push_audio_segment(state, cache, pad, sample) do
    duration_range = state.segment_duration_range
    end_timestamp = max_end_timestamp(state) + duration_range.min

    any_video_tracks? =
      Enum.any?(state.samples_cache, fn {_pad, cache} -> cache.supports_keyframes? end)

    if any_video_tracks? do
      Cache.force_push(cache, sample)
    else
      Cache.push(cache, sample, end_timestamp)
    end
    |> case do
      %Cache{state: :collecting} = cache ->
        {:ok, update_cache_for(pad, cache, state)}

      %Cache{state: :to_collect} = cache ->
        collect_samples_for_audio_track(pad, cache, state)
    end
  end

  @spec push_partial_segment(state_t(), Membrane.Pad.ref_t(), Membrane.Buffer.t()) ::
          {:ok, state_t()} | {:ok, segment_t(), state_t()}
  def push_partial_segment(state, pad, sample) do
    cache = Map.fetch!(state.samples_cache, pad)

    if cache.supports_keyframes? do
      push_partial_video_segment(state, cache, pad, sample)
    else
      push_partial_audio_segment(state, cache, pad, sample)
    end
  end

  defp push_partial_video_segment(state, cache, pad, sample) do
    %{
      partial_segment_duration_range: part_duration_range,
      segment_duration_range: duration_range
    } = state

    collected_duration = cache.collected_duration

    total_collected_durations =
      Map.fetch!(state.pad_to_track_data, pad).parts_duration + collected_duration

    base_timestamp = max_end_timestamp(state)

    if total_collected_durations < duration_range.min do
      Cache.push_part(cache, sample, base_timestamp + part_duration_range.target)
    else
      min_timestamp = base_timestamp + part_duration_range.min
      mid_timestamp = base_timestamp + part_duration_range.target
      max_timestamp = base_timestamp + part_duration_range.min + part_duration_range.target

      Cache.push_part(cache, sample, min_timestamp, mid_timestamp, max_timestamp)
    end
    |> case do
      %Cache{state: :collecting} = cache ->
        {:ok, update_cache_for(pad, cache, state)}

      %Cache{state: :to_collect} = cache ->
        pad
        |> collect_samples_for_video_track(cache, state)
        |> maybe_reset_partial_durations()
    end
  end

  @spec take_all_samples(state_t()) :: {:ok, segment_t(), state_t()}
  def take_all_samples(state) do
    segment =
      state.samples_cache
      |> Enum.reject(fn {_pad, cache} -> Cache.empty?(cache) end)
      |> Enum.map(fn {pad, cache} ->
        {samples, _cache} = Cache.drain_samples(cache)

        {pad, samples}
      end)
      |> Map.new()

    {:ok, segment, state}
  end

  @spec take_all_samples_for(state_t(), Membrane.Time.t()) :: {:ok, segment_t(), state_t()}
  def take_all_samples_for(state, duration) do
    end_timestamp = max_end_timestamp(state) + duration

    {segment, state} =
      state.samples_cache
      |> Enum.reject(fn {_pad, cache} -> Cache.empty?(cache) end)
      |> Enum.reduce({[], state}, fn {pad, cache}, {acc, state} ->
        {samples, cache} = Cache.force_collect(cache, end_timestamp)

        {[{pad, samples} | acc], update_cache_for(pad, cache, state)}
      end)

    maybe_reset_partial_durations({:ok, Map.new(segment), state})
  end

  defp push_partial_audio_segment(state, cache, pad, sample) do
    %{
      partial_segment_duration_range: part_duration_range,
      segment_duration_range: duration_range
    } = state

    any_video_tracks? =
      Enum.any?(state.samples_cache, fn {_pad, cache} -> cache.supports_keyframes? end)

    # if we have any video track then let the video track decide when to collect audio tracks
    if any_video_tracks? do
      cache = Cache.force_push(cache, sample)

      {:ok, update_cache_for(pad, cache, state)}
    else
      parts_duration = parts_duration_for(pad, state)

      base_timestamp = max_end_timestamp(state)

      duration =
        min(
          part_duration_range.target,
          max(part_duration_range.min, duration_range.target - parts_duration)
        )

      case Cache.push_part(cache, sample, base_timestamp + duration) do
        %Cache{state: :collecting} = cache ->
          {:ok, update_cache_for(pad, cache, state)}

        %Cache{state: :to_collect} = cache ->
          pad
          |> collect_samples_for_audio_track(cache, state)
          |> maybe_reset_partial_durations()
      end
    end
  end

  defp update_cache_for(pad, cache, state), do: put_in(state, [:samples_cache, pad], cache)

  defp collect_samples_for_video_track(pad, cache, state) do
    end_timestamp = Cache.last_collected_dts(cache)

    {collected, cache} = Cache.collect(cache)

    state = update_cache_for(pad, cache, state)

    if tracks_ready_for_collection?(state, end_timestamp) do
      state = update_partial_duration(state, pad, collected)

      {segment, state} =
        state.samples_cache
        |> Map.delete(pad)
        |> collect_segment_from_cache(end_timestamp, state)

      segment = Map.put(segment, pad, collected)

      {:ok, segment, state}
    else
      {:ok, update_cache_for(pad, cache, state)}
    end
  end

  defp collect_samples_for_audio_track(pad, cache, state) do
    end_timestamp = Cache.last_collected_dts(cache)
    state = update_cache_for(pad, cache, state)

    if tracks_ready_for_collection?(state, end_timestamp) do
      {segment, state} = collect_segment_from_cache(state.samples_cache, end_timestamp, state)

      {:ok, segment, state}
    else
      {:ok, state}
    end
  end

  defp collect_segment_from_cache(cache_per_pad, end_timestamp, state) do
    Enum.reduce(cache_per_pad, {%{}, state}, fn {pad, cache}, {acc, state} ->
      {collected, cache} = Cache.force_collect(cache, end_timestamp)

      state =
        pad
        |> update_cache_for(cache, state)
        |> update_partial_duration(pad, collected)

      {Map.put(acc, pad, collected), update_cache_for(pad, cache, state)}
    end)
  end

  defp tracks_ready_for_collection?(state, end_timestamp) do
    Enum.all?(state.samples_cache, fn {_pad, cache} ->
      Cache.last_collected_dts(cache) >= end_timestamp
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
