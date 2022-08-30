defmodule Membrane.MP4.Muxer.CMAF.Segment.Helper do
  @moduledoc false
  use Bunch

  alias Membrane.MP4.Muxer.CMAF.SegmentDurationRange

  @eps 1.0e-6

  @type segment_t :: %{
          (pad :: any()) => [Membrane.Buffer.t()]
        }

  @type segment_result_t ::
          {:ok, segment :: segment_t(), state :: map()} | {:error, :not_enough_data}

  @spec get_segment(map(), SegmentDurationRange.t()) :: segment_result_t()
  def get_segment(state, duration_range) do
    min_end_timestamp = calculate_end_timestamps(state, duration_range.min)

    with {:ok, min_segment, state} <- collect_minimum_duration(state, min_end_timestamp),
         {:ok, target_segment, state} <-
           collect_until_keyframes(state) do
      segment = merge_segments(min_segment, target_segment)
      {:ok, segment, state}
    end
  end

  @spec get_partial_segment(map(), SegmentDurationRange.t(), SegmentDurationRange.t()) ::
          segment_result_t()
  def get_partial_segment(state, duration_range, partial_duration_range) do
    partial_segments_duration =
      state.pad_to_track_data
      |> Enum.map(fn {_key, data} -> data.partial_segments_duration end)
      |> Enum.max()

    cond do
      # there duration will be less than minimum, collect full partial segment
      partial_segments_duration + partial_duration_range.target - duration_range.min - @eps < 0 ->
        target_end_timestamp = calculate_end_timestamps(state, partial_duration_range.target)

        collect_minimum_duration(state, target_end_timestamp)

      # the partial segment will be the first to exceed the minimum full segment duration,
      # collect up to the min segment duration and then lookup further partial segments and try to look for key frames
      partial_segments_duration - duration_range.min - @eps < 0 ->
        min_duration =
          max(duration_range.min - partial_segments_duration, partial_duration_range.min)

        remaining_duration = partial_duration_range.target - min_duration

        # if the remaining duration is not relevant then just skip it
        durations =
          if remaining_duration > 0.1 * min_duration do
            [
              min_duration,
              min_duration + remaining_duration,
              min_duration + remaining_duration + partial_duration_range.min
            ]
          else
            [min_duration]
          end

        maybe_collect_partial_segment_until_keyframe(state, durations)

      # there is enough duration to finish a partial segment,
      # try to assemble at least the target duration while still looking for key frames
      # to finish the segment quicker
      partial_segments_duration - duration_range.min + @eps >= 0 ->
        %SegmentDurationRange{min: min, target: target} = partial_duration_range

        maybe_collect_partial_segment_until_keyframe(state, [min, target, min + target])

      true ->
        raise "Invalid durations of all partial segments"
    end
  end

  defp maybe_collect_partial_segment_until_keyframe(state, []) do
    {:ok, %{}, state}
  end

  defp maybe_collect_partial_segment_until_keyframe(state, [duration | durations]) do
    end_timestamp = calculate_end_timestamps(state, duration)

    with {:ok, partial_segment1, state1} <- collect_minimum_duration(state, end_timestamp),
         {:ok, partial_segment2, state2} <-
           maybe_collect_partial_segment_until_keyframe(state1, durations) do
      if has_keyframe(partial_segment2) do
        {:ok, partial_segment3, state3} = collect_until_keyframes(state1)

        {:ok, merge_segments(partial_segment1, partial_segment3), reset_partial_durations(state3)}
      else
        # the last duration is a lookahead so don't merge it
        if length(durations) == 1 do
          {:ok, partial_segment1, state1}
        else
          {:ok, merge_segments(partial_segment1, partial_segment2), state2}
        end
      end
    end
  end

  defp collect_minimum_duration(state, min_end_timestamp) do
    partial_segments =
      for {track, samples} <- state.samples do
        collect_from_track_to_timestamp(track, samples, min_end_timestamp)
      end

    if Enum.any?(partial_segments, &(&1 == {:error, :not_enough_data})) do
      {:error, :not_enough_data}
    else
      state =
        Enum.reduce(partial_segments, state, fn {:ok, {track, segment, leftover}}, state ->
          update_track(track, segment, leftover, state)
        end)

      segment =
        Map.new(partial_segments, fn {:ok, {track, segment, _leftover}} ->
          {track, Enum.reverse(segment)}
        end)

      {:ok, segment, state}
    end
  end

  defp calculate_end_timestamps(state, duration) do
    elapsed_time =
      Enum.map(state.pad_to_track_data, fn {_key, track_data} ->
        Ratio.to_float(track_data.elapsed_time)
      end)
      |> Enum.max()

    elapsed_time + duration
  end

  defp merge_segments(segment1, segment2) do
    Map.new(segment1, fn {pad, samples} ->
      samples2 = Map.get(segment2, pad, [])
      {pad, samples ++ samples2}
    end)
  end

  @spec take_all_samples(map()) :: {:ok, map(), map()}
  def take_all_samples(state) do
    samples = Map.new(state.samples, fn {key, samples} -> {key, Enum.reverse(samples)} end)

    {:ok, samples, %{state | samples: %{}}}
  end

  @spec get_discontinuity_segment(map(), Membrane.Time.t()) :: segment_result_t()
  def get_discontinuity_segment(state, duration) do
    with {:ok, segment, state} <- get_segment(state, SegmentDurationRange.new(duration)) do
      {:ok, segment, %{state | awaiting_caps: nil}}
    end
  end

  defp update_track(track, segment, leftover, state) do
    durations =
      Enum.reduce(segment, 0, fn sample, durations ->
        durations + sample.metadata.duration
      end)

    state
    |> put_in([:samples, track], leftover)
    |> update_in([:pad_to_track_data, track, :partial_segments_duration], &(&1 + durations))
  end

  defp has_keyframe(segment) do
    map_size(segment) > 0 and
      Enum.all?(segment, fn {_track, samples} ->
        Enum.any?(samples, &is_key_frame/1)
      end)
  end

  defp collect_from_track_to_timestamp(_track, [], _target_duration),
    do: {:error, :not_enough_data}

  defp collect_from_track_to_timestamp(track, samples, desired_end) do
    use Ratio, comparison: true

    {leftover, samples} = Enum.split_while(samples, &(&1.dts > desired_end))

    with [sample | _rest] <- samples,
         true <- sample.dts + sample.metadata.duration >= desired_end do
      {:ok, {track, samples, leftover}}
    else
      _other ->
        {:error, :not_enough_data}
    end
  end

  # Collects the samples until there is a keyframe on all tracks.
  # 1. Check if all tracks begin with keyframe. If that is the case, algorithm finishes
  # 2. Select the track with the smallest dts at the beginning. Collect samples until it doesn't have the smallest dts.
  # 3. Go to step 1
  defp collect_until_keyframes(state) do
    with {:ok, segment, state} <- do_collect_until_keyframes(reverse_samples(state)) do
      {:ok, segment, reverse_samples(state)}
    end
  end

  defp do_collect_until_keyframes(state) do
    use Ratio, comparison: true

    {target_pad, _samples} =
      Enum.min_by(state.samples, fn {_track, samples} ->
        case samples do
          [] ->
            :infinity

          [sample | _rest] ->
            Ratio.to_float(sample.dts)
        end
      end)

    # if samples' dts differ between each other with at most of 1 sample duration
    # then the timestamps are balanced
    timestamps_balanced? =
      state.samples
      |> Enum.map(fn {_track, samples} ->
        case samples do
          [] -> nil
          [sample | _rest] -> {sample.dts, sample.metadata.duration}
        end
      end)
      |> check_timestamps_balanced()

    cond do
      Enum.any?(state.samples, fn {_track, samples} -> samples == [] end) ->
        {:error, :not_enough_data}

      timestamps_balanced? and
          Enum.all?(state.samples, fn {_track, samples} -> starts_with_keyframe?(samples) end) ->
        {:ok, %{}, state}

      true ->
        {sample, state} = get_and_update_in(state, [:samples, target_pad], &List.pop_at(&1, 0))

        with {:ok, segment, state} <- do_collect_until_keyframes(state) do
          segment = Map.update(segment, target_pad, [sample], &[sample | &1])
          {:ok, segment, state}
        end
    end
  end

  defp check_timestamps_balanced([first, second | rest]) do
    with {dts1, duration1} <- first,
         {dts2, duration2} <- second do
      max_duration =
        if Ratio.gt?(duration1, duration2) do
          duration1
        else
          duration2
        end

      balanced? = Ratio.lte?(Ratio.abs(Ratio.sub(dts1, dts2)), max_duration)

      balanced? and check_timestamps_balanced([second | rest])
    else
      _other ->
        # if either first or second are nils then we can't know
        # if timestamps are balanced
        false
    end
  end

  defp check_timestamps_balanced(_timestamps), do: true

  defp reset_partial_durations(state) do
    state
    |> Map.update!(:pad_to_track_data, fn entries ->
      entries
      |> Map.new(fn {pad, data} -> {pad, Map.replace(data, :partial_segments_duration, 0)} end)
    end)
  end

  @compile {:inline, is_key_frame: 1}
  defp is_key_frame(%{metadata: metadata}),
    do: Map.get(metadata, :mp4_payload, %{}) |> Map.get(:key_frame?, true)

  defp starts_with_keyframe?([]), do: false

  defp starts_with_keyframe?([target | _rest]),
    do: is_key_frame(target)

  defp reverse_samples(state),
    do:
      Map.update!(
        state,
        :samples,
        &Map.new(&1, fn {key, samples} -> {key, Enum.reverse(samples)} end)
      )
end
