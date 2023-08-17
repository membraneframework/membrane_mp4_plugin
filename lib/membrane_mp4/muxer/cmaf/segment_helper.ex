defmodule Membrane.MP4.Muxer.CMAF.SegmentHelper do
  @moduledoc false

  use Bunch

  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: SamplesQueue
  alias Membrane.Pad

  @type pad_t :: Membrane.Pad.ref()
  @type state_t :: map()

  @type segment_t :: %{
          pad_t() => [Membrane.Buffer.t()]
        }

  @doc """
  Collects media samples for a segment/chunk once they are ready for collection.

  Samples are ready for collection in the following scenarios:
  - a new stream format has been received (force collect the current segment)
  - target duration has been collected and no key frame is expected (in case of dependent/partial segments)
  - minimum duration has been collected and a key frame arrived
  """
  @spec collect_segment_samples(state :: term(), Pad.ref(), Membrane.Buffer.t() | nil) ::
          {actions :: [term()],
           {:segment, segment :: term(), state :: term()} | {:no_segment, state :: term()}}
  def collect_segment_samples(%{awaiting_stream_format: nil} = state, _pad, nil),
    do: {[], {:no_segment, state}}

  def collect_segment_samples(%{awaiting_stream_format: nil} = state, pad, sample),
    do: do_collect_segment_samples(state, pad, sample)

  def collect_segment_samples(
        %{awaiting_stream_format: {{:update_with_next, _pad}, _stream_format}} = state,
        pad,
        sample
      ),
      do: do_collect_segment_samples(state, pad, sample)

  def collect_segment_samples(
        %{awaiting_stream_format: {:stream_format, stream_format}} = state,
        pad,
        sample
      ) do
    state = %{state | awaiting_stream_format: nil}

    unless is_key_frame(state.pad_to_track_data[pad].buffer_awaiting_duration) do
      raise "Video sample received after new stream format must be a key frame"
    end

    {:no_segment, state} = force_push_segment(state, pad, sample)

    {:segment, _segment, _state} = result = take_all_samples_until(state, sample)

    {[stream_format: {:output, stream_format}], result}
  end

  defp do_collect_segment_samples(state, pad, sample) do
    supports_partial_segments? = state.chunk_duration_range != nil

    if supports_partial_segments? do
      {[], push_chunk(state, pad, sample)}
    else
      {[], push_segment(state, pad, sample)}
    end
  end

  @doc """
  Puts an awaiting stream format that needs to be handled when
  a next samples arrives.
  """
  @spec put_awaiting_stream_format(Pad.ref(), term(), term()) :: term()
  def put_awaiting_stream_format(pad, stream_format, state) do
    %{state | awaiting_stream_format: {{:update_with_next, pad}, stream_format}}
  end

  @doc """
  Updates the awaiting stream format to a ready state where it can be finally handled.
  """
  @spec update_awaiting_stream_format(state :: term(), Pad.ref()) :: state :: term()
  def update_awaiting_stream_format(
        %{awaiting_stream_format: {{:update_with_next, pad}, stream_format}} = state,
        pad
      ) do
    %{state | awaiting_stream_format: {:stream_format, stream_format}}
  end

  def update_awaiting_stream_format(state, _pad), do: state

  @spec push_segment(state_t(), Membrane.Pad.ref(), Membrane.Buffer.t()) ::
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

    queue =
      if state.finish_current_segment? do
        # we want to get a segment with any duration
        tmp_duration_range = Membrane.MP4.Muxer.CMAF.DurationRange.new(0)

        {queue, duration_range} = replace_queue_duration_range(queue, tmp_duration_range)
        queue = SamplesQueue.push_until_target(queue, sample, base_timestamp)
        {queue, _tmp_duration_range} = replace_queue_duration_range(queue, duration_range)

        queue
      else
        SamplesQueue.push_until_target(queue, sample, base_timestamp)
      end

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

  @spec push_chunk(state_t(), Membrane.Pad.ref(), Membrane.Buffer.t()) ::
          {:no_segment, state_t()} | {:segment, segment_t(), state_t()}
  def push_chunk(state, pad, sample) do
    queue = Map.fetch!(state.sample_queues, pad)

    if queue.track_with_keyframes? do
      push_video_chunk(state, queue, pad, sample)
    else
      push_audio_chunk(state, queue, pad, sample)
    end
  end

  @spec is_key_frame(Membrane.Buffer.t()) :: boolean()
  def is_key_frame(%{metadata: metadata}),
    do: Map.get(metadata, :h264, %{}) |> Map.get(:key_frame?, true)

  defp push_video_chunk(state, queue, pad, sample) do
    collected_duration = queue.collected_samples_duration

    total_collected_durations =
      Map.fetch!(state.pad_to_track_data, pad).chunks_duration + collected_duration

    base_timestamp = state.pad_to_track_data[pad].segment_base_timestamp

    queue =
      cond do
        state.finish_current_segment? ->
          SamplesQueue.push_until_end(queue, sample, base_timestamp)

        total_collected_durations < state.segment_min_duration ->
          SamplesQueue.plain_push_until_target(queue, sample, base_timestamp)

        true ->
          SamplesQueue.push_until_end(queue, sample, base_timestamp)
      end

    if queue.collectable? do
      pad
      |> collect_samples_for_video_track(queue, state)
      |> maybe_reset_chunk_durations(sample)
    else
      {:no_segment, update_queue_for(pad, queue, state)}
    end
  end

  @spec force_push_segment(state_t(), Membrane.Pad.ref(), Membrane.Buffer.t()) ::
          {:no_segment, state_t()}
  def force_push_segment(state, pad, sample) do
    queue = Map.fetch!(state.sample_queues, pad)

    queue = SamplesQueue.force_push(queue, sample)
    {:no_segment, update_queue_for(pad, queue, state)}
  end

  @spec take_all_samples(state_t()) :: {:segment, segment_t(), state_t()}
  def take_all_samples(state) do
    state
    |> do_take_sample(&SamplesQueue.drain_samples/1)
    |> force_reset_chunks_duration()
  end

  @spec take_all_samples_until(state_t(), Membrane.Buffer.t()) ::
          {:segment, segment_t(), state_t()}
  def take_all_samples_until(state, sample) do
    state
    |> do_take_sample(&SamplesQueue.force_collect(&1, sample.dts))
    |> force_reset_chunks_duration()
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
  end

  defp push_audio_chunk(state, queue, pad, sample) do
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
        |> maybe_reset_chunk_durations(sample)
      else
        {:no_segment, update_queue_for(pad, queue, state)}
      end
    end
  end

  defp update_queue_for(pad, queue, state), do: put_in(state, [:sample_queues, pad], queue)

  defp collect_samples_for_video_track(pad, queue, state) do
    end_timestamp = SamplesQueue.last_collected_dts(queue)
    state = update_queue_for(pad, queue, state)

    if tracks_ready_for_collection?(state, end_timestamp) do
      {collected, queue} = SamplesQueue.collect(queue)

      state = update_partial_duration(state, pad, collected)
      state = update_queue_for(pad, queue, state)

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

  defp replace_queue_duration_range(
         %SamplesQueue{duration_range: old_duration_range} = queue,
         duration_range
       ) do
    {%SamplesQueue{queue | duration_range: duration_range}, old_duration_range}
  end

  defp update_partial_duration(state, pad, samples) do
    duration = Enum.reduce(samples, 0, &(&1.metadata.duration + &2))

    update_in(state, [:pad_to_track_data, pad, :chunks_duration], &(&1 + duration))
  end

  defp maybe_return_segment(segment, state) do
    if Enum.any?(segment, fn {_pad, samples} -> not Enum.empty?(samples) end) do
      {:segment, segment, state}
    else
      {:no_segment, state}
    end
  end

  defp maybe_reset_chunk_durations(result, next_sample)

  defp maybe_reset_chunk_durations({:no_segment, _state} = result, _next_sample), do: result

  defp maybe_reset_chunk_durations({:segment, segment, state}, next_sample) do
    min_duration = state.segment_min_duration

    next_segment_independent? = is_key_frame(next_sample)

    enough_duration? =
      Enum.all?(state.pad_to_track_data, fn {pad, data} ->
        data.chunks_duration >= min_duration and not (Map.get(segment, pad, []) |> Enum.empty?())
      end)

    state =
      if next_segment_independent? and (state.finish_current_segment? or enough_duration?) do
        reset_chunks_duration(state)
      else
        state
      end

    maybe_return_segment(segment, state)
  end

  defp force_reset_chunks_duration({:no_segment, _state} = result), do: result

  defp force_reset_chunks_duration({:segment, segment, state}) do
    maybe_return_segment(segment, reset_chunks_duration(state))
  end

  defp max_segment_base_timestamp(state) do
    state.pad_to_track_data
    |> Enum.reject(fn {_key, track_data} -> is_nil(track_data.segment_base_timestamp) end)
    |> Enum.map(fn {_key, track_data} ->
      Ratio.to_float(track_data.segment_base_timestamp)
    end)
    |> Enum.max()
  end

  defp reset_chunks_duration(state) do
    state
    |> Map.update!(:pad_to_track_data, fn entries ->
      entries
      |> Map.new(fn {pad, data} -> {pad, Map.replace(data, :chunks_duration, 0)} end)
    end)
  end
end
