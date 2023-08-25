defmodule Membrane.MP4.Muxer.CMAF do
  @moduledoc """
  Puts a payloaded stream into [Common Media Application Format](https://www.wowza.com/blog/what-is-cmaf),
  an MP4-based container commonly used in adaptive streaming over HTTP.

  The element supports up to 2 input tracks that can result in one output:
    - audio input -> audio output
    - video input -> video output
    - video input + audio input -> muxed audio and video output

  ## Media objects
  Accordingly to the spec, the `#{inspect(__MODULE__)}` is able to assemble the following media entities:
    * `headers` - media initialization object. Contains information necessary to play the media segments (when binary
    concatenated with a media segment it creates a valid MP4 file). The media header is sent as an output pad's stream format.

  * `segments` - media data that when combined with media headers can be played independently to other segments.
    Segments due to their nature (video decoding) must start with a key frame (doesn't apply to audio-only tracks) which
    is a main driver when collecting video samples and deciding when a segment should be created

  * `chunks` - fragmented media data that when binary concatenated should make up a regular segment. Chunks
    no longer have the requirement to start with a key frame (except for the first chunk that starts a new segment)
    and their main goal is to reduce the latency of creating the media segments (chunks can be delivered to a client faster so it can
    start playing them before a full segment gets assembled)

  ### Segment/Chunk metadata
  Each outgoing buffer containing a segment/chunk contains the following fields in the buffer's metadata:
  * `duration` - the duration of the underlying segment/chunk

  * `independent?` - tells if a segment/chunk can be independently played (starts with a keyframe), it is always true for segments

  * `last_chunk?` - tells if the underlying chunk is the last one of the segment currently being assembled, for segments this flag is always true
    and has no real meaning

  ## Segment creation
  A segment gets created based on the duration of currently collected media samples and
    `:segment_min_duration` options passed when initializing `#{inspect(__MODULE__)}`.

  It is expected that the segment will not be shorter than the specified minimum duration value
  and the aim is to end the segment as soon as the next key frames arrives that will become
  a part of a new segment.

  If a user prefers to have segments of unified durations then he needs to take into consideration
  the incoming keyframes interval. For instance, if a keyframe interval is 2 seconds and the goal is to have
  6 seconds segments then the minimum segment duration should be lower than 6 seconds (the key frame at the
  6-second mark will force the segment finalization).

  > ### Note
  > If a key frame comes at irregular intervals, the segment could be much longer than expected as after the minimum
  > duration muxer will always look for a key frame to finish the segment.

  ## Forcing segment creation
  It may happen that one may need to create a segment before it reaches the minimum duration (for purposes such as fast AD insertion).

  To instruct the muxer to finalize the current segment as soon as possible one can send `Membrane.MP4.Muxer.CMAF.RequestMediaFinalization`
  event on the `:output` pad. The event will enforce the muxer to end the current segment as soon as possible (usually on the nearest key frame).
  After the segment gets generated, the muxer will go back to its normal behaviour of creating segments.

  ## Chunk creation
  As previously mentioned, chunks are not required to start with a key frame except for
  a first chunk of a new segment. Those are once again created based on the duration of the collected
  samples but this time the process needs to be smarter as we can't allow the chunk to significantly exceed
  their target duration.

  Exceeding the chunk's target duration can cause unrecoverable player stalls e.g. when
  playing LL-HLS on Safari, same goes if the chunk's duration is lower than 85% of the target duration
  when the chunk is the not last of its parent segment (Safari again). This is why
  proper duration MUST get collected. The limitation does not apply to the last chunk of a given regular segment.

  The behaviour of creating chunk is as follows:
  * if the duration of the **regular** segment currently being assembled is lower than the minimum then
    try to collect chunk with its given `target` duration value no matter what

  * if the duration of the **regular** segment currently being assembled is greater than the minimum then try to
    finish the chunk as fast as possible (without exceeding the chunk's target) when encountering a key frame. When such chunk
    gets created it also means that its parent segment is also done.

  Note that once the `#{inspect(__MODULE__)}` is in a phase of finalizing a **regular** segment, more than one
  chunk could get created until a key frame is encountered.

  > ### Important for video {: .warning}
  >
  > `:chunk_target_duration` should be chosen with special care and appropriately for its use case.
  > It is unnecessary to create chunks when the target use case is not live streaming.
  >
  > The chunk duration usability may depend on its use case e.g. for live streaming there is very little value for having duration higher
  > than 1s/2s, also having really short duration may add a communication overhead for a client (a necessity for downloading many small chunks).

  > ## Note
  > If a stream contains non-key frames (like H264 P or B frames), they should be marked
  > with a `h264: %{key_frame?: false}` metadata entry.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.{Header, Segment, DurationRange, SegmentHelper}
  alias Membrane.{Buffer, H264}
  alias Membrane.MP4.{Helper, Track}
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: SamplesQueue

  def_input_pad :input,
    availability: :on_request,
    demand_unit: :buffers,
    accepted_format:
      any_of(
        %Membrane.AAC{config: {:esds, _esds}},
        %Membrane.Opus{self_delimiting?: false},
        %Membrane.H264{
          stream_structure: {avc, _dcr},
          alignment: :au
        }
        when avc in [:avc1, :avc3]
      )

  def_output_pad :output, accepted_format: Membrane.CMAF.Track

  def_options segment_min_duration: [
                spec: Membrane.Time.t(),
                default: Membrane.Time.seconds(2),
                description: """
                Minimum duration of a regular media segment.

                When the minimum duration is reached the muxer will try to finalize the segment as soon as
                a new key frame arrives which will start a new segment.
                """
              ],
              chunk_target_duration: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                desription: """
                Target duration for media chunks.

                Note that when chunks get created, no segments will be emitted. Created chunks
                are assumed to be part of a segment.

                If set to `nil`, the muxer assumes it should not produce chunks.
                """
              ]

  @impl true
  def handle_init(_ctx, options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        seq_num: 0,
        # stream format waiting to be sent after receiving the next buffer.
        # Holds the structure {stream_format_timestamp, stream_format}
        awaiting_stream_format: nil,
        pad_to_track_data: %{},
        # ID for the next input track
        next_track_id: 1,
        sample_queues: %{},
        finish_current_segment?: false
      })
      |> set_chunk_duration_range()

    {[], state}
  end

  @impl true
  def handle_pad_added(_pad, ctx, _state) when ctx.playback == :playing,
    do:
      raise(
        "New tracks can be added to #{inspect(__MODULE__)} only before playback transition to :playing"
      )

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    {track_id, state} = Map.get_and_update!(state, :next_track_id, &{&1, &1 + 1})

    track_data = %{
      id: track_id,
      track: nil,
      # base timestamp of the current segment, initialized with DTS of the first buffer
      # and then incremented by duration of every produced segment
      segment_base_timestamp: nil,
      end_timestamp: 0,
      buffer_awaiting_duration: nil,
      chunks_duration: Membrane.Time.seconds(0)
    }

    state
    |> put_in([:pad_to_track_data, pad], track_data)
    |> put_in([:sample_queues, pad], %SamplesQueue{
      duration_range: state.chunk_duration_range || DurationRange.new(state.segment_min_duration)
    })
    |> then(&{[], &1})
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, state) do
    {pad, _elapsed_time} =
      state.pad_to_track_data
      |> Enum.map(fn {pad, track_data} -> {pad, track_data.end_timestamp} end)
      |> Enum.reject(fn {_key, timestamp} -> is_nil(timestamp) end)
      |> Enum.min_by(fn {_key, timestamp} -> Ratio.to_float(timestamp) end)

    {[demand: {pad, 1}], state}
  end

  @impl true
  def handle_stream_format(pad, stream_format, ctx, state) do
    ensure_max_one_video_pad!(pad, stream_format, ctx)

    is_video_pad = is_video(stream_format)

    state =
      state
      |> update_in(
        [:pad_to_track_data, pad],
        &%{&1 | track: stream_format_to_track(stream_format, &1.id)}
      )
      |> update_in(
        [:sample_queues, pad],
        &%SamplesQueue{&1 | track_with_keyframes?: is_video_pad}
      )

    has_all_input_stream_formats? =
      ctx.pads
      |> Map.drop([:output, pad])
      |> Map.values()
      |> Enum.all?(&(&1.stream_format != nil))

    if has_all_input_stream_formats? do
      stream_format = generate_output_stream_format(state)

      cond do
        is_nil(ctx.pads.output.stream_format) ->
          {[stream_format: {:output, stream_format}], state}

        stream_format != ctx.pads.output.stream_format ->
          {[], SegmentHelper.put_awaiting_stream_format(pad, stream_format, state)}

        true ->
          {[], state}
      end
    else
      {[], state}
    end
  end

  defp is_video(%Track{stream_format: stream_format}), do: is_struct(stream_format, H264)
  defp is_video(stream_format), do: is_struct(stream_format, H264)

  defp find_video_pads(ctx) do
    ctx.pads
    |> Enum.filter(fn
      {Pad.ref(:input, _id), data} ->
        data.stream_format != nil and is_video(data.stream_format)

      _other ->
        false
    end)
    |> Enum.map(fn {pad, _data} -> pad end)
  end

  defp ensure_max_one_video_pad!(pad, stream_format, ctx) do
    is_video_pad = is_video(stream_format)

    if is_video_pad do
      video_pads = find_video_pads(ctx)

      has_other_video_pad? = video_pads != [] and video_pads != [pad]

      if has_other_video_pad? do
        raise "CMAF muxer can only handle at most one video pad"
      end
    end
  end

  defp stream_format_to_track(stream_format, track_id) do
    Track.new(track_id, stream_format)
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, sample, ctx, state) do
    use Ratio, comparison: true

    # In case DTS is not set, use PTS. This is the case for audio tracks or H264 originated
    # from an RTP stream. ISO base media file format specification uses DTS for calculating
    # decoding deltas, and so is the implementation of sample table in this plugin.
    sample = %Buffer{sample | dts: Buffer.get_dts_or_pts(sample)}

    {sample, state} =
      state
      |> maybe_init_segment_base_timestamp(pad, sample)
      |> process_buffer_awaiting_duration(pad, sample)

    state = SegmentHelper.update_awaiting_stream_format(state, pad)

    {stream_format_action, segment} = SegmentHelper.collect_segment_samples(state, pad, sample)

    case segment do
      {:segment, segment, state} ->
        {buffer, state} = generate_segment(segment, ctx, state)

        actions = [buffer: {:output, buffer}] ++ stream_format_action ++ [redemand: :output]

        {actions, state}

      {:no_segment, state} ->
        {[redemand: :output], state}
    end
  end

  @impl true
  def handle_event(:output, %__MODULE__.RequestMediaFinalization{}, _ctx, state) do
    {[], %{state | finish_current_segment?: true}}
  end

  @impl true
  def handle_event(Pad.ref(:input, _ref), event, _ctx, state) do
    {[forward: event], state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _track_id) = pad, ctx, state) do
    cache = Map.fetch!(state.sample_queues, pad)

    processing_finished? =
      ctx.pads
      |> Map.drop([:output, pad])
      |> Map.values()
      |> Enum.all?(& &1.end_of_stream?)

    if SamplesQueue.empty?(cache) do
      if processing_finished? do
        {[end_of_stream: :output], state}
      else
        {[redemand: :output], state}
      end
    else
      generate_end_of_stream_segment(processing_finished?, cache, pad, ctx, state)
    end
  end

  defp generate_end_of_stream_segment(processing_finished?, cache, pad, ctx, state) do
    sample = state.pad_to_track_data[pad].buffer_awaiting_duration

    sample_metadata =
      Map.put(sample.metadata, :duration, SamplesQueue.last_sample(cache).metadata.duration)

    sample = %Buffer{sample | metadata: sample_metadata}

    cache = SamplesQueue.force_push(cache, sample)
    state = put_in(state, [:sample_queues, pad], cache)

    if processing_finished? do
      with {:segment, segment, state} when map_size(segment) > 0 <-
             SegmentHelper.take_all_samples(state) do
        {buffer, state} = generate_segment(segment, ctx, state)
        {[buffer: {:output, buffer}, end_of_stream: :output], state}
      else
        {:segment, _segment, state} -> {[end_of_stream: :output], state}
      end
    else
      state = put_in(state, [:pad_to_track_data, pad, :end_timestamp], nil)

      {[redemand: :output], state}
    end
  end

  defp generate_output_stream_format(state) do
    tracks = Enum.map(state.pad_to_track_data, fn {_pad, track_data} -> track_data.track end)

    resolution =
      tracks
      |> Enum.find_value(fn
        %Track{stream_format: %H264{width: width, height: height}} -> {width, height}
        _audio_track -> nil
      end)

    codecs = Map.new(tracks, fn track -> Track.get_encoding_info(track) end)

    header = Header.serialize(tracks)

    content_type =
      tracks
      |> Enum.map(&if is_video(&1), do: :video, else: :audio)
      |> then(fn
        [item] -> item
        list -> list
      end)

    %Membrane.CMAF.Track{
      content_type: content_type,
      header: header,
      resolution: resolution,
      codecs: codecs
    }
  end

  defp generate_segment(acc, ctx, state) do
    use Ratio, comparison: true

    tracks_data =
      acc
      |> Enum.filter(fn {_pad, samples} -> not Enum.empty?(samples) end)
      |> Enum.map(fn {pad, samples} ->
        track_data = state.pad_to_track_data[pad]

        %{timescale: timescale} = track_data.track
        first_sample = hd(samples)
        last_sample = List.last(samples)

        samples_table =
          samples
          |> Enum.map(fn sample ->
            %{
              sample_size: byte_size(sample.payload),
              sample_flags: generate_sample_flags(sample.metadata),
              sample_duration:
                Helper.timescalify(
                  sample.metadata.duration,
                  timescale
                )
                |> Ratio.trunc(),
              sample_offset: Helper.timescalify(sample.pts - sample.dts, timescale)
            }
          end)

        samples_data = Enum.map_join(samples, & &1.payload)

        duration = last_sample.dts - first_sample.dts + last_sample.metadata.duration

        %{
          pad: pad,
          id: state.pad_to_track_data[pad].id,
          sequence_number: state.seq_num,
          base_timestamp:
            Helper.timescalify(track_data.segment_base_timestamp, timescale)
            |> Ratio.trunc(),
          unscaled_duration: duration,
          duration: Helper.timescalify(duration, timescale),
          timescale: timescale,
          samples_table: samples_table,
          samples_data: samples_data
        }
      end)

    payload = Segment.serialize(tracks_data)

    # Duration of the tracks will never be exactly the same. To minimize the error and avoid its magnification over time,
    # duration of the segment is assumed to be the average of tracks' durations.
    duration =
      tracks_data
      |> Enum.map(&Ratio.to_float(&1.unscaled_duration))
      |> then(&(Enum.sum(&1) / length(&1)))
      |> floor()

    metadata = %{
      duration: duration,
      independent?: is_segment_independent(acc, ctx),
      last_chunk?: is_segment_finished(state)
    }

    buffer = %Buffer{payload: payload, metadata: metadata}

    # Update segment base timestamps for each track
    state =
      Enum.reduce(tracks_data, state, fn %{unscaled_duration: duration, pad: pad}, state ->
        update_in(state, [:pad_to_track_data, pad, :segment_base_timestamp], &(&1 + duration))
      end)
      |> Map.update!(:seq_num, &(&1 + 1))
      |> Map.update!(:finish_current_segment?, fn finish_current_segment? ->
        non_ending_chunk? = metadata.last_chunk? == false

        finish_current_segment? and non_ending_chunk?
      end)

    {buffer, state}
  end

  defp is_segment_independent(segment, ctx) do
    case find_video_pads(ctx) do
      [] ->
        true

      [video_pad] ->
        case segment do
          %{^video_pad => samples} ->
            hd(samples).metadata.h264.key_frame?

          _other ->
            true
        end
    end
  end

  defp is_segment_finished(%{pad_to_track_data: data}) do
    # if `chunk_duration` is set to zero then it means
    # that a new segment just started and the current one is finished
    Enum.all?(data, fn {_pad, track_data} ->
      track_data.chunks_duration == 0
    end)
  end

  defp generate_sample_flags(metadata) do
    key_frame? = metadata |> Map.get(:h264, %{}) |> Map.get(:key_frame?, true)

    is_leading = 0
    depends_on = if key_frame?, do: 2, else: 1
    is_depended_on = 0
    has_redundancy = 0
    padding_value = 0
    non_sync = if key_frame?, do: 0, else: 1
    degradation_priority = 0

    <<0::4, is_leading::2, depends_on::2, is_depended_on::2, has_redundancy::2, padding_value::3,
      non_sync::1, degradation_priority::16>>
  end

  # Update the duration of the awaiting sample and insert the current sample into the queue
  defp process_buffer_awaiting_duration(state, pad, sample) do
    use Ratio

    prev_sample = state.pad_to_track_data[pad].buffer_awaiting_duration

    if is_nil(prev_sample) do
      {nil, put_in(state, [:pad_to_track_data, pad, :buffer_awaiting_duration], sample)}
    else
      duration = Ratio.to_float(sample.dts - prev_sample.dts)
      prev_sample_metadata = Map.put(prev_sample.metadata, :duration, duration)
      prev_sample = %Buffer{prev_sample | metadata: prev_sample_metadata}

      state =
        state
        |> put_in([:pad_to_track_data, pad, :end_timestamp], prev_sample.dts)
        |> put_in([:pad_to_track_data, pad, :buffer_awaiting_duration], sample)

      {prev_sample, state}
    end
  end

  defp maybe_init_segment_base_timestamp(state, pad, sample) do
    case state do
      %{pad_to_track_data: %{^pad => %{segment_base_timestamp: nil}}} ->
        put_in(state, [:pad_to_track_data, pad, :segment_base_timestamp], sample.dts)

      _else ->
        state
    end
  end

  @min_chunk_duration Membrane.Time.milliseconds(50)
  defp set_chunk_duration_range(
         %{
           chunk_target_duration: chunk_target_duration
         } = state
       )
       when is_integer(chunk_target_duration) do
    if chunk_target_duration < @min_chunk_duration do
      raise """
        Chunk target duration is smaller than minimal duration.
        Duration: #{Membrane.Time.round_to_milliseconds(chunk_target_duration)}
        Minumum: #{Membrane.Time.round_to_milliseconds(@min_chunk_duration)}
      """
    end

    state
    |> Map.delete(:chunk_target_duration)
    |> Map.put(
      :chunk_duration_range,
      DurationRange.new(@min_chunk_duration, chunk_target_duration)
    )
  end

  defp set_chunk_duration_range(state) do
    state
    |> Map.delete(:chunk_target_duration)
    |> Map.put(:chunk_duration_range, nil)
  end
end
