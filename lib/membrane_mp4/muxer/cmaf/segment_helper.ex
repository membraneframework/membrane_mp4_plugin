defmodule Membrane.MP4.Muxer.CMAF.Segment.Helper do
  @moduledoc false
  use Bunch

  @spec get_segment(map(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, map(), map()} | {:error, :not_enough_data}
  def get_segment(state, duration, partial_duration \\ nil) do
    with {:ok, segment_part_1, state} <- collect_duration(state, partial_duration || duration),
         {:ok, segment_part_2, state} <-
           collect_until_keyframes(state, duration, partial_duration) do
      segment =
        Map.new(segment_part_1, fn {pad, samples} ->
          samples_part_2 = Map.get(segment_part_2, pad, [])
          {pad, samples ++ samples_part_2}
        end)

      {:ok, segment, state}
    end
  end

  @spec take_all_samples(map()) :: {:ok, map(), map()}
  def take_all_samples(state) do
    samples = Map.new(state.samples, fn {key, samples} -> {key, Enum.reverse(samples)} end)

    {:ok, samples, %{state | samples: %{}}}
  end

  @spec get_discontinuity_segment(map(), non_neg_integer()) ::
          {:error, :not_enough_data} | {:ok, map, map}
  def get_discontinuity_segment(state, duration) do
    with {:ok, segment, state} <- get_segment(state, duration) do
      {:ok, segment, %{state | awaiting_caps: nil}}
    end
  end

  # Collects partial CMAF segment so that the length matches given duration
  defp collect_duration(state, target_duration) do
    use Ratio

    end_timestamp =
      Enum.map(state.pad_to_track_data, fn {_key, track_data} ->
        Ratio.to_float(track_data.elapsed_time + target_duration)
      end)
      |> Enum.max()

    partial_segments =
      for {track, samples} <- state.samples do
        collect_from_track_to_timestamp(track, samples, end_timestamp)
      end

    if Enum.any?(partial_segments, &(&1 == {:error, :not_enough_data})) do
      {:error, :not_enough_data}
    else
      state =
        Enum.reduce(partial_segments, state, fn {:ok, {track, segment, leftover}}, state ->
          durations =
            Enum.reduce(segment, 0, fn sample, durations ->
              durations + sample.metadata.duration
            end)

          state
          |> put_in([:samples, track], leftover)
          |> update_in([:pad_to_track_data, track, :partial_segments_duration], &(&1 + durations))
        end)

      segment =
        Map.new(partial_segments, fn {:ok, {track, segment, _leftover}} ->
          {track, Enum.reverse(segment)}
        end)

      {:ok, segment, state}
    end
  end

  defp collect_from_track_to_timestamp(_track, [], _target_duration),
    do: {:error, :not_enough_data}

  defp collect_from_track_to_timestamp(track, samples, desired_end) do
    use Ratio, comparison: true

    {leftover, samples} = Enum.split_while(samples, &(&1.dts >= desired_end))

    if hd(samples).dts + hd(samples).metadata.duration >= desired_end do
      {:ok, {track, samples, leftover}}
    else
      {:error, :not_enough_data}
    end
  end

  # Collects the samples until there is a keyframe on all tracks.
  # 1. Check if all tracks begin with keyframe. If that is the case, algorithm finishes
  # 2. Select the track with the smallest dts at the beginning. Collect samples until it doesn't have the smallest dts.
  # 3. Go to step 1
  defp collect_until_keyframes(state, _duration, nil) do
    with {:ok, segment, state} <- do_collect_until_keyframes(reverse_samples(state), nil) do
      {:ok, segment, reverse_samples(state)}
    end
  end

  defp collect_until_keyframes(state, duration, _partial_duration) do
    %{partial_segments_duration: partial_segments_duration} =
      state.pad_to_track_data
      |> Map.values()
      |> Enum.max_by(& &1.partial_segments_duration)

    reset_partial_durations = fn state ->
      state
      |> Map.update!(:pad_to_track_data, fn entries ->
        entries
        |> Map.new(fn {pad, data} -> {pad, Map.replace(data, :partial_segments_duration, 0)} end)
      end)
    end

    cond do
      # in case we reached the desired segment duration and we are allowed
      # to finalize the segment but only if the next sample is a key frame
      duration - partial_segments_duration <= 0 and
          Enum.any?(state.samples, fn {_track, samples} ->
            samples |> List.last([]) |> starts_with_keyframe?()
          end) ->
        {:ok, %{}, reset_partial_durations.(state)}

      # partial durations exceeded the target segment duration, seek for keyframe
      duration - partial_segments_duration <= 0 ->
        state
        |> collect_until_keyframes(duration, nil)
        |> case do
          {:ok, segment, state} ->
            {:ok, segment, reset_partial_durations.(state)}

          other ->
            other
        end

      true ->
        {:ok, %{}, state}
    end
  end

  defp do_collect_until_keyframes(state, last_target_pad) do
    use Ratio, comparison: true

    {target_pad, _samples} =
      Enum.min_by(state.samples, fn {_track, samples} ->
        case samples do
          [] -> :infinity
          [sample | _rest] -> Ratio.to_float(sample.dts + sample.metadata.duration)
        end
      end)

    # This holds true if and only if all tracks are balanced to begin with.
    # Therefore, this algorithm will not destroy the balance of tracks, but it is not guaranteed to restore it
    timestamps_balanced? =
      target_pad != last_target_pad or Map.keys(state.samples) == [target_pad]

    cond do
      Enum.any?(state.samples, fn {_track, samples} -> samples == [] end) ->
        {:error, :not_enough_data}

      timestamps_balanced? and
          Enum.all?(state.samples, fn {_track, samples} -> starts_with_keyframe?(samples) end) ->
        {:ok, %{}, state}

      true ->
        {sample, state} = get_and_update_in(state, [:samples, target_pad], &List.pop_at(&1, 0))

        with {:ok, segment, state} <- do_collect_until_keyframes(state, target_pad) do
          segment = Map.update(segment, target_pad, [sample], &[sample | &1])
          {:ok, segment, state}
        end
    end
  end

  defp starts_with_keyframe?([]), do: false

  defp starts_with_keyframe?([target | _rest]),
    do: Map.get(target.metadata, :mp4_payload, %{}) |> Map.get(:key_frame?, true)

  defp starts_with_keyframe?(%Membrane.Buffer{metadata: metadata}),
    do: Map.get(metadata, :mp4_payload, %{}) |> Map.get(:key_frame?, true)

  defp reverse_samples(state),
    do:
      Map.update!(
        state,
        :samples,
        &Map.new(&1, fn {key, samples} -> {key, Enum.reverse(samples)} end)
      )
end
