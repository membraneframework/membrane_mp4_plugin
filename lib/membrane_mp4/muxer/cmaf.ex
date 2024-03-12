defmodule Membrane.MP4.Muxer.CMAF do
  @moduledoc """
  Puts a payloaded stream into [Common Media Application Format](https://www.wowza.com/blog/what-is-cmaf),
  an MP4-based container commonly used in adaptive streaming over HTTP.


  ## Input/Output tracks matrix
  The basic muxer's functionality is to take a single media stream and put it into CMAF formatted track.

  Sometimes one may need to mux several tracks together or make sure that output tracks are
  synchronized with each other. Such behavior is also supported by the muxer's implementation.

  Each output pad can specify which input pads needs to be muxed together by specifying `:tracks` option.

  One may also want to have separate output pads that are internally synchronized with each other (then
  the `:tracks` should contain only a single id). By synchronization we mean that the muxer will try its best
  to produce equal length segments for output pads. The synchronization relies on the video track (the video
  track can only be cut at keyframe boundries, audio track can be cut at any point).

  This approach enforces that there is no more than a single video track. A video track is always used as a synchronization point
  therefore having more than one would make the synchronization decisions ambiguous. The amount of audio tracks on the other
  hand is not limited.

  As a rule of thumb, if there is no need to synchronize tracks just use separate muxer instances.

  The example matrix of possible input/ouput tracks is as follows:
  - audio input -> audio output
  - video input -> video output
  - audio input + video input  -> muxed audio/video output
  - audio-1 input + ... + audio-n input + video input  -> audio-1 output + ... + audio-n output  + video output

  ## Media objects
  Accordingly to the spec, the `#{inspect(__MODULE__)}` is able to assemble the following media entities:
    * `header` - media initialization object. Contains information necessary to play the media segments.
    The media header content is sent inside of a stream format on the target output pad.

  * `segment` - a sequence of one or more consecutive fragments belonging to a particular track that are playable on their own
    when combined with a media header.
    Segments due to their nature (video decoding) must start with a key frame (doesn't apply to audio-only tracks) which
    is a main driver when collecting video samples and deciding when a segment should be created

  * `chunk` - a fragment consisting of a subset of media samples, not necessairly playable on its own. Chunk
    no longer has the requirement to start with a key frame (except for the first chunk that starts a new segment)
    and its main goal is to reduce the latency of creating the media segments (chunks can be delivered to a client faster so it can
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
  and the aim is to end the segment as soon as the next key frames arrives (for audio-only tracks the segment can be ended after each sample)
  that will become a part of a new segment.

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
  event on any `:output` pad. The event will enforce the muxer to end the current segment as soon as possible (usually on the nearest key frame).
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
  require Membrane.H264
  require Membrane.H265

  alias __MODULE__.{Header, Segment, DurationRange, SegmentHelper}
  alias Membrane.{AAC, H264, H265, Opus}
  alias Membrane.Buffer
  alias Membrane.MP4.{Helper, Track}
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: SamplesQueue

  def_input_pad :input,
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format:
      any_of(
        %AAC{config: {:esds, _esds}},
        %Opus{self_delimiting?: false},
        %H264{stream_structure: structure, alignment: :au} when H264.is_avc(structure),
        %H265{stream_structure: structure, alignment: :au} when H265.is_hvc(structure)
      )

  def_output_pad :output,
    availability: :on_request,
    options: [
      tracks: [
        spec: [Membrane.Pad.dynamic_id()] | :all,
        default: :all,
        description: """
        A list of the input pad ids that should be muxed together into a single output track.

        If not specified the pad will include all unreferenced input pads.
        """
      ]
    ],
    accepted_format: Membrane.CMAF.Track,
    flow_control: :manual

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
        # stream formats waiting to be sent after receiving the next buffer.
        # Holds the structure {stream_format_timestamp, stream_format}
        awaiting_stream_formats: %{},
        pad_to_track_data: %{},
        pads_registration_order: [],
        sample_queues: %{},
        finish_current_segment?: false,
        video_pad: nil,
        all_input_pads_ready?: false,
        buffers_awaiting_init: []
      })
      |> set_chunk_duration_range()

    {[], state}
  end

  @impl true
  def handle_pad_added(_pad, ctx, _state) when ctx.playback == :playing,
    do:
      raise(
        "New pads can be added to #{inspect(__MODULE__)} only before playback transition to :playing"
      )

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    {[], Map.update!(state, :pads_registration_order, &[pad | &1])}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, _id), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_playing(ctx, state) do
    {registration_order, state} = Map.pop!(state, :pads_registration_order)

    registration_order = Enum.reverse(registration_order)

    pads = Map.keys(ctx.pads)

    %{
      input: input_pads,
      output: output_pads
    } = Enum.group_by(pads, fn Pad.ref(type, _id) -> type end)

    if Enum.empty?(output_pads) do
      raise "Expected at least a single output pad"
    end

    input_groups =
      input_pads
      |> prepare_input_groups(output_pads, ctx)
      |> tap(&validate_input_groups!/1)

    input_to_output_pad =
      input_groups
      |> Enum.flat_map(fn {output_pad, input_pads} ->
        Enum.map(input_pads, &{&1, output_pad})
      end)
      |> Map.new()

    state =
      Map.merge(state, %{
        input_groups: input_groups,
        input_to_output_pad: input_to_output_pad,
        seq_nums: Map.new(output_pads, &{&1, 0})
      })

    input_pad_track_ids =
      input_groups
      |> Map.values()
      |> Enum.flat_map(fn pads ->
        pads
        |> Enum.sort_by(fn pad -> Enum.find_index(registration_order, &(&1 == pad)) end)
        |> Enum.with_index(1)
      end)

    state =
      Enum.reduce(input_pad_track_ids, state, &initialize_pad_track_data/2)

    demands = Enum.map(input_pads, &{:demand, &1})

    {demands, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, _id) = pad, _size, _unit, _ctx, state) do
    case state.input_groups[pad] do
      [input_pad] ->
        {[demand: {input_pad, 1}], state}

      input_pads ->
        state.pad_to_track_data
        |> Map.take(input_pads)
        |> Enum.map(fn {pad, track_data} -> {pad, track_data.end_timestamp} end)
        |> Enum.reject(fn {_key, timestamp} -> is_nil(timestamp) end)
        |> Enum.min_by(fn {_key, timestamp} -> Ratio.to_float(timestamp) end)
        |> then(fn {pad, _time} -> {[demand: {pad, 1}], state} end)
    end
  end

  @impl true
  def handle_stream_format(pad, stream_format, ctx, state) do
    ensure_max_one_video_pad!(pad, stream_format, state)

    output_pad = state.input_to_output_pad[pad]

    is_video_pad = video?(stream_format)

    state =
      state
      |> update_in(
        [:pad_to_track_data, pad],
        &%{&1 | track: Track.new(&1.id, stream_format)}
      )
      |> update_in(
        [:sample_queues, pad],
        &%SamplesQueue{&1 | track_with_keyframes?: is_video_pad}
      )
      |> then(fn state ->
        if is_video_pad do
          %{state | video_pad: pad}
        else
          state
        end
      end)

    if are_all_group_pads_ready?(pad, ctx, state) do
      stream_format = generate_output_stream_format(output_pad, state)

      old_input_pads_ready? = state.all_input_pads_ready?

      state = update_input_pads_ready(pad, ctx, state)

      {actions, state} =
        if old_input_pads_ready? != state.all_input_pads_ready? do
          replay_init_buffers(ctx, state)
        else
          {[], state}
        end

      cond do
        is_nil(ctx.pads[output_pad].stream_format) ->
          {[{:stream_format, {output_pad, stream_format}} | actions], state}

        stream_format != ctx.pads[output_pad].stream_format ->
          {actions, SegmentHelper.put_awaiting_stream_format(pad, stream_format, state)}

        true ->
          {actions, state}
      end
    else
      {[], state}
    end
  end

  @impl true
  def handle_buffer(Pad.ref(:input, _id) = pad, sample, ctx, state)
      when state.all_input_pads_ready? do
    use Numbers, overload_operators: true, comparison: true

    # In case DTS is not set, use PTS. This is the case for audio tracks or H264 originated
    # from an RTP stream. ISO base media file format specification uses DTS for calculating
    # decoding deltas, and so is the implementation of sample table in this plugin.
    sample = %Buffer{sample | dts: Buffer.get_dts_or_pts(sample)}

    {sample, state} =
      state
      |> maybe_init_segment_timestamps(pad, sample)
      |> process_buffer_awaiting_duration(pad, sample)

    state = SegmentHelper.update_awaiting_stream_format(state, pad)

    {stream_format_action, segment} = SegmentHelper.collect_segment_samples(state, pad, sample)

    case segment do
      {:segment, segment, state} ->
        {buffers, state} = generate_segment_actions(segment, ctx, state)

        actions =
          buffers ++
            stream_format_action ++
            Enum.map(buffers, fn {:buffer, {pad, _buffer}} -> {:redemand, pad} end)

        {actions, state}

      {:no_segment, state} ->
        output_pad = state.input_to_output_pad[pad]
        {[redemand: output_pad], state}
    end
  end

  @impl true
  def handle_buffer(pad, sample, _ctx, state) do
    {[], %{state | buffers_awaiting_init: [{pad, sample} | state.buffers_awaiting_init]}}
  end

  @impl true
  def handle_event(_pad, %__MODULE__.RequestMediaFinalization{}, _ctx, state) do
    {[], %{state | finish_current_segment?: true}}
  end

  @impl true
  def handle_event(Pad.ref(:input, _ref) = pad, event, _ctx, state) do
    output_pad = state.input_to_output_pad[pad]

    {[event: {output_pad, event}], state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _track_id) = pad, ctx, state) do
    cache = Map.fetch!(state.sample_queues, pad)
    output_pad = state.input_to_output_pad[pad]

    input_pads = Map.keys(state.input_to_output_pad) -- [pad]

    processing_finished? =
      ctx.pads
      |> Map.take(input_pads)
      |> Map.values()
      |> Enum.all?(& &1.end_of_stream?)

    if SamplesQueue.empty?(cache) do
      if processing_finished? do
        end_of_streams = generate_output_end_of_streams(ctx)

        {end_of_streams, state}
      else
        {[redemand: output_pad], state}
      end
    else
      generate_end_of_stream_segment(processing_finished?, pad, ctx, state)
    end
  end

  defp prepare_input_groups(input_pads, output_pads, ctx) do
    available_tracks = Enum.map(input_pads, fn Pad.ref(:input, id) -> id end)

    Map.new(output_pads, fn output_pad ->
      tracks =
        case ctx.pads[output_pad].options.tracks do
          :all -> available_tracks
          tracks when is_list(tracks) -> tracks
        end

      unless Enum.all?(tracks, &(&1 in available_tracks)) do
        raise "Encountered unknown pad in specified tracks: #{inspect(tracks)}, available tracks: #{inspect(available_tracks)}"
      end

      input_pads =
        tracks
        |> Enum.uniq()
        |> Enum.map(&Pad.ref(:input, &1))

      {output_pad, input_pads}
    end)
  end

  defp validate_input_groups!(input_groups) do
    input_groups
    |> Map.values()
    |> List.flatten()
    |> Bunch.Enum.duplicates()
    |> case do
      [] ->
        :ok

      pads ->
        raise "Input pads #{inspect(pads)} are used in more than one input group."
    end
  end

  defp initialize_pad_track_data({pad, track_id}, state) do
    track_data = %{
      id: track_id,
      track: nil,
      # decoding timestamp of the current segment, initialized with DTS of the first buffer
      # and then incremented by duration of every produced segment
      segment_decoding_timestamp: nil,
      # presentation timestamp of the current segment, initialized with PTS of the first buffer
      # and then incremented by duration of every produced segment
      segment_presentation_timestamp: nil,
      end_timestamp: 0,
      buffer_awaiting_duration: nil,
      chunks_duration: Membrane.Time.seconds(0)
    }

    state
    |> put_in([:pad_to_track_data, pad], track_data)
    |> put_in([:sample_queues, pad], %SamplesQueue{
      duration_range: state.chunk_duration_range || DurationRange.new(state.segment_min_duration)
    })
  end

  defp generate_end_of_stream_segment(false, pad, _ctx, state) do
    output_pad = state.input_to_output_pad[pad]

    state = put_in(state, [:pad_to_track_data, pad, :end_timestamp], nil)

    {[redemand: output_pad], state}
  end

  defp generate_end_of_stream_segment(true, _pad, ctx, state) do
    state =
      for {pad, track_data} <- state.pad_to_track_data, reduce: state do
        state ->
          queue = Map.fetch!(state.sample_queues, pad)
          sample = track_data.buffer_awaiting_duration

          sample_metadata =
            Map.put(sample.metadata, :duration, SamplesQueue.last_sample(queue).metadata.duration)

          sample = %Buffer{sample | metadata: sample_metadata}

          queue = SamplesQueue.force_push(queue, sample)
          put_in(state, [:sample_queues, pad], queue)
      end

    end_of_streams = generate_output_end_of_streams(ctx)

    case SegmentHelper.take_all_samples(state) do
      {:segment, segment, state} when map_size(segment) > 0 ->
        {buffers, state} = generate_segment_actions(segment, ctx, state)

        {buffers ++ end_of_streams, state}

      {:segment, _segment, state} ->
        {end_of_streams, state}
    end
  end

  defp generate_output_stream_format(output_pad, state) do
    input_pads = state.input_groups[output_pad]

    tracks =
      state.pad_to_track_data
      |> Map.take(input_pads)
      |> Enum.map(fn {_pad, track_data} -> track_data.track end)

    resolution =
      tracks
      |> Enum.find_value(fn
        %Track{stream_format: %H264{width: width, height: height}} -> {width, height}
        %Track{stream_format: %H265{width: width, height: height}} -> {width, height}
        _audio_track -> nil
      end)

    codecs = Map.new(tracks, &Track.get_encoding_info/1)

    header = Header.serialize(tracks)

    content_type =
      tracks
      |> Enum.map(&if video?(&1.stream_format), do: :video, else: :audio)
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

  defp generate_output_end_of_streams(ctx) do
    ctx.pads
    |> Enum.filter(fn
      {Pad.ref(:output, _id), data} -> not data.end_of_stream?
      _other -> false
    end)
    |> Enum.map(fn {pad, _data} ->
      {:end_of_stream, pad}
    end)
  end

  defp generate_samples_table(samples, timescale) do
    Enum.map(samples, fn sample ->
      %{
        sample_size: byte_size(sample.payload),
        sample_flags: generate_sample_flags(sample.metadata),
        sample_duration:
          sample.metadata.duration
          |> Helper.timescalify(timescale)
          |> Ratio.trunc(),
        sample_offset: Helper.timescalify(sample.pts - sample.dts, timescale)
      }
    end)
  end

  defp generate_samples_data(samples) do
    samples
    |> Enum.map(& &1.payload)
    |> IO.iodata_to_binary()
  end

  defp calculate_segment_duration(samples) do
    first_sample = hd(samples)
    last_sample = List.last(samples)

    last_sample.dts - first_sample.dts + last_sample.metadata.duration
  end

  defp generate_input_group_tracks_data(
         input_group,
         acc,
         state
       ) do
    {output_pad, input_pads} = input_group

    tracks_data =
      acc
      |> Map.take(input_pads)
      |> Enum.filter(fn {_pad, samples} -> not Enum.empty?(samples) end)
      |> Enum.map(fn {pad, samples} ->
        track_data = state.pad_to_track_data[pad]

        %{timescale: timescale} = track_data.track

        duration = calculate_segment_duration(samples)

        %{
          pad: pad,
          id: track_data.id,
          sequence_number: state.seq_nums[output_pad],
          timescale: timescale,
          base_timestamp:
            track_data.segment_presentation_timestamp
            |> Helper.timescalify(timescale)
            |> Ratio.trunc(),
          unscaled_duration: duration,
          duration: Helper.timescalify(duration, timescale),
          samples_table: generate_samples_table(samples, timescale),
          samples_data: generate_samples_data(samples)
        }
      end)

    if Enum.empty?(tracks_data) do
      {[], state}
    else
      state =
        tracks_data
        |> Enum.reduce(state, fn %{unscaled_duration: duration, pad: pad}, state ->
          state
          |> update_in([:pad_to_track_data, pad, :segment_decoding_timestamp], &(&1 + duration))
          |> update_in(
            [:pad_to_track_data, pad, :segment_presentation_timestamp],
            &(&1 + duration)
          )
        end)
        |> update_in([:seq_nums, output_pad], &(&1 + 1))

      {[{input_group, tracks_data}], state}
    end
  end

  defp generate_input_group_action({input_group, tracks_data}, acc, state) do
    {output_pad, _input_pads} = input_group

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
      independent?: segment_independent?(acc, state),
      last_chunk?: segment_finished?(state)
    }

    {:buffer, {output_pad, %Buffer{payload: payload, metadata: metadata}}}
  end

  defp update_finish_current_segment_state(actions, state) do
    last_chunk? =
      Enum.any?(actions, fn {:buffer, {_pad, buffer}} -> buffer.metadata.last_chunk? end)

    Map.update!(state, :finish_current_segment?, fn finish_current_segment? ->
      non_ending_chunk? = last_chunk? == false

      finish_current_segment? and non_ending_chunk?
    end)
  end

  defp generate_segment_actions(acc, _ctx, state) do
    use Numbers, overload_operators: true, comparison: true

    state.input_groups
    |> Enum.flat_map_reduce(state, &generate_input_group_tracks_data(&1, acc, &2))
    |> then(fn {data, state} ->
      actions = Enum.map(data, &generate_input_group_action(&1, acc, state))

      state = update_finish_current_segment_state(actions, state)

      {actions, state}
    end)
  end

  defp segment_independent?(segment, state) do
    video_pad = state.video_pad

    case segment do
      %{^video_pad => samples} -> Helper.key_frame?(hd(samples).metadata)
      _other -> true
    end
  end

  defp segment_finished?(%{pad_to_track_data: data}) do
    # if `chunk_duration` is set to zero then it means
    # that a new segment just started and the current one is finished
    Enum.all?(data, fn {_pad, track_data} ->
      track_data.chunks_duration == 0
    end)
  end

  defp generate_sample_flags(metadata) do
    key_frame? = Helper.key_frame?(metadata)

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
    use Numbers, overload_operators: true

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

  defp maybe_init_segment_timestamps(state, pad, sample) do
    case state do
      %{pad_to_track_data: %{^pad => %{segment_decoding_timestamp: nil}}} ->
        update_in(state, [:pad_to_track_data, pad], fn data ->
          Map.merge(data, %{
            segment_decoding_timestamp: sample.dts,
            segment_presentation_timestamp: sample.pts
          })
        end)

      _else ->
        state
    end
  end

  defp update_input_pads_ready(pad, ctx, state) do
    all_input_pads_ready? =
      Enum.all?(ctx.pads, fn
        {^pad, _data} -> true
        {Pad.ref(:output, _id), _data} -> true
        {Pad.ref(:input, _id), data} -> data.stream_format != nil
      end)

    %{state | all_input_pads_ready?: all_input_pads_ready?}
  end

  defp replay_init_buffers(ctx, state) do
    {buffers, state} = Map.pop!(state, :buffers_awaiting_init)

    Enum.flat_map_reduce(buffers, state, fn {pad, buffer}, state ->
      handle_buffer(pad, buffer, ctx, state)
    end)
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
        Duration: #{Membrane.Time.as_milliseconds(chunk_target_duration, :round)}
        Minumum: #{Membrane.Time.as_milliseconds(@min_chunk_duration, :round)}
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

  defp are_all_group_pads_ready?(pad, ctx, state) do
    output_pad = state.input_to_output_pad[pad]

    other_input_pads = state.input_groups[output_pad] -- [pad]

    ctx.pads
    |> Map.take(other_input_pads)
    |> Enum.all?(fn {_pad, data} -> data.stream_format != nil end)
  end

  defp video?(stream_format),
    do: is_struct(stream_format, H264) or is_struct(stream_format, H265)

  defp ensure_max_one_video_pad!(pad, stream_format, state) do
    if video?(stream_format) and state.video_pad != nil and state.video_pad != pad do
      raise "CMAF muxer can only handle at most one video pad"
    end
  end
end
