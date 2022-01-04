defmodule Membrane.MP4.Muxer.CMAF.Segment.Helper do
  @moduledoc false
  use Bunch

  @spec get_segment(map(), non_neg_integer()) :: {:ok, map(), map()} | {:error, :not_enough_data}
  def get_segment(state, duration) do
    with {:ok, segment_part_1, state} <- collect_duration(state, duration),
         {:ok, segment_part_2, state} <- collect_until_keyframes(state) do
      segment =
        Map.new(segment_part_1, fn {key, value} ->
          part_2 = Map.get(segment_part_2, key, [])
          {key, value ++ part_2}
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

  defp collect_duration(state, target_duration) do
    use Ratio

    end_timestamp =
      Enum.map(state.pad_to_track, fn {_key, track_data} ->
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
        Enum.reduce(partial_segments, state, fn {:ok, {track, _segment, leftover}}, state ->
          put_in(state, [:samples, track], leftover)
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

    {leftover, segment} = Enum.split_while(samples, &(&1.dts > desired_end))

    if hd(segment).dts + hd(segment).metadata.duration >= desired_end do
      {:ok, {track, segment, leftover}}
    else
      {:error, :not_enough_data}
    end
  end

  # Finds the next keyframe that is in the same place on all pads. This would be significantly more readable in iterative form, but here we go:
  # 1. Check if all tracks begin with keyframe. If that is the case, algorithm finishes
  # 2. Select the track with the smallest dts at the beginning. Buffer exactly one sample until it doesn't have the smallest dts.
  # 3. Go to step 1
  defp collect_until_keyframes(state, last_target_pad \\ nil) do
    use Ratio, comparison: true

    {target_pad, _samples} =
      Enum.min_by(state.samples, fn {_track, samples} ->
        case List.last(samples) do
          nil -> :infinity
          sample -> Ratio.to_float(sample.dts + sample.metadata.duration)
        end
      end)

    cond do
      (target_pad != last_target_pad or Map.keys(state.samples) == [last_target_pad]) and
          Enum.all?(state.samples, fn {_track, samples} -> starts_with_keyframe?(samples) end) ->
        {:ok, %{}, state}

      Enum.any?(state.samples, fn {_track, samples} -> samples == [] end) ->
        {:error, :not_enough_data}

      true ->
        {sample, state} = get_and_update_in(state, [:samples, target_pad], &List.pop_at(&1, -1))

        with {:ok, segment, state} <- collect_until_keyframes(state, target_pad) do
          segment = Map.update(segment, target_pad, [sample], &[sample | &1])
          {:ok, segment, state}
        end
    end
  end

  defp starts_with_keyframe?(target) do
    last = List.last(target)
    length(target) > 0 and Map.get(last.metadata, :mp4_payload, %{}) |> Map.get(:key_frame?, true)
  end
end
