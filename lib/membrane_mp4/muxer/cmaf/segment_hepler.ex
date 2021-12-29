defmodule Membrane.MP4.Muxer.CMAF.Segment.Helper do
  @moduledoc false
  use Bunch

  @spec get_segment(map(), non_neg_integer()) :: {:ok, map(), map()} | {:error, :not_enough_data}
  def get_segment(state, duration) do
    with {:ok, segment_part_1, state} <- get_to_duration(state, duration),
         {:ok, segment_part_2, state} <- get_to_next_keyframe(state) do
      segment =
        Map.new(segment_part_1, fn {key, value} ->
          part_2 =
            segment_part_2
            |> Map.get(key, [])

          {key, value ++ part_2}
        end)

      {:ok, segment, state}
    end
  end

  @spec clear_samples(map()) :: {:ok, map(), map()}
  def clear_samples(state) do
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

  defp get_to_duration(state, target_duration) do
    partial_segments =
      for {track, samples} <- state.samples do
        single_track_take_duration(track, samples, target_duration)
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

  defp single_track_take_duration(_track, [], _target_duration), do: {:error, :not_enough_data}

  defp single_track_take_duration(track, samples, target_duration) do
    use Ratio, comparison: true

    desired_end = List.last(samples).dts + target_duration
    {leftover, segment} = Enum.split_while(samples, &(&1.dts > desired_end))

    if hd(segment).dts + hd(segment).metadata.duration >= desired_end do
      {:ok, {track, segment, leftover}}
    else
      {:error, :not_enough_data}
    end
  end

  defp get_to_next_keyframe(state) do
    use Ratio, comparison: true

    cond do
      Enum.all?(state.samples, fn {_track, samples} -> starts_with_keyframe?(samples) end) ->
        {:ok, %{}, state}

      Enum.any?(state.samples, fn {_track, samples} -> samples == [] end) ->
        {:error, :not_enough_data}

      true ->
        {target_pad, _samples} =
          Enum.min_by(state.samples, fn {_track, samples} ->
            sample = List.last(samples)
            Ratio.to_float(sample.dts + sample.metadata.duration)
          end)

        {sample, state} = get_and_update_in(state, [:samples, target_pad], &List.pop_at(&1, -1))

        with {:ok, segment, state} <- get_to_next_keyframe(state) do
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
