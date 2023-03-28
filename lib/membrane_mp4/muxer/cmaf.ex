defmodule Membrane.MP4.Muxer.CMAF do
  @moduledoc """
  Puts payloaded stream into [Common Media Application Format](https://www.wowza.com/blog/what-is-cmaf),
  an MP4-based container commonly used in adaptive streaming over HTTP.

  Multiple input streams are supported. If that is the case, they will be muxed into a single CMAF Track.
  Given that all input streams need to have a keyframe at the beginning of each CMAF Segment, it is recommended
  that all input streams are renditions of the same content.

  The muxer also supports creation of partial segments that do not begin with a key frame
  when the `partial_segment_duration_range` is specified. The muxer tries to create many partial
  segments to match the regular segment target duration. When reaching the regular segment's
  target duration the muxer tries to perform lookaheads of the samples to either create
  a shorter/longer partial segment so that a new segment can be started (beginning with a keyframe).

  If a stream contains non-key frames (like H264 P or B frames), they should be marked
  with a `mp4_payload: %{key_frame?: false}` metadata entry.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.{Header, Segment, SegmentDurationRange, SegmentHelper}
  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Payload.AVC1
  alias Membrane.MP4.{Helper, Track}
  alias Membrane.MP4.Muxer.CMAF.TrackSamplesQueue, as: SamplesQueue

  def_input_pad :input,
    availability: :on_request,
    demand_unit: :buffers,
    accepted_format: Membrane.MP4.Payload

  def_output_pad :output, accepted_format: Membrane.CMAF.Track

  def_options segment_duration_range: [
                spec: SegmentDurationRange.t(),
                default: SegmentDurationRange.new(Time.seconds(2), Time.seconds(2))
              ],
              partial_segment_duration_range: [
                spec: SegmentDurationRange.t() | nil,
                default: nil,
                description: """
                The duration range of partial segments.

                If set to `nil`, the muxer assumes it should not produce partial segments
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
        sample_queues: %{}
      })

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
      parts_duration: Membrane.Time.seconds(0)
    }

    state
    |> put_in([:pad_to_track_data, pad], track_data)
    |> put_in([:sample_queues, pad], %SamplesQueue{
      duration_range: state.partial_segment_duration_range || state.segment_duration_range
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
  def handle_stream_format(pad, %Membrane.MP4.Payload{} = stream_format, ctx, state) do
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
          {[], put_awaiting_stream_format(pad, stream_format, state)}

        true ->
          {[], state}
      end
    else
      {[], state}
    end
  end

  # public for tests 
  @spec put_awaiting_stream_format(Pad.ref_t(), term(), term()) :: term()
  def put_awaiting_stream_format(pad, stream_format, state) do
    %{state | awaiting_stream_format: {{:update_with_next, pad}, stream_format}}
  end

  # public for tests
  @spec update_awaiting_stream_format(state :: term(), Pad.ref_t()) :: state :: term()
  def update_awaiting_stream_format(
        %{awaiting_stream_format: {{:update_with_next, pad}, stream_format}} = state,
        pad
      ) do
    %{state | awaiting_stream_format: {:stream_format, stream_format}}
  end

  def update_awaiting_stream_format(state, _pad), do: state

  defp is_video(stream_format_or_track), do: is_struct(stream_format_or_track.content, AVC1)

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
    stream_format
    |> Map.from_struct()
    |> Map.take([:width, :height, :content, :timescale])
    |> Map.put(:id, track_id)
    |> Track.new()
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

    state = update_awaiting_stream_format(state, pad)

    {stream_format_action, segment} = collect_segment_samples(state, pad, sample)

    case segment do
      {:segment, segment, state} ->
        {buffer, state} = generate_segment(segment, ctx, state)
        actions = [buffer: {:output, buffer}] ++ stream_format_action ++ [redemand: :output]
        {actions, state}

      {:no_segment, state} ->
        {[redemand: :output], state}
    end
  end

  # public for tests
  @spec collect_segment_samples(state :: term(), Pad.ref_t(), Membrane.Buffer.t() | nil) ::
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

    unless SegmentHelper.is_key_frame(state.pad_to_track_data[pad].buffer_awaiting_duration) do
      raise "Video sample received after new stream format must be a key frame"
    end

    {:no_segment, state} = force_push_sample(state, pad, sample)
    {:segment, _segment, _state} = result = SegmentHelper.take_all_samples_until(state, sample)

    {[stream_format: {:output, stream_format}], result}
  end

  defp do_collect_segment_samples(state, pad, sample) do
    supports_partial_segments? = state.partial_segment_duration_range != nil

    if supports_partial_segments? do
      {[], SegmentHelper.push_partial_segment(state, pad, sample)}
    else
      {[], SegmentHelper.push_segment(state, pad, sample)}
    end
  end

  defp force_push_sample(state, pad, sample) do
    SegmentHelper.force_push_segment(state, pad, sample)
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
      header: header
    }
  end

  defp generate_segment(acc, ctx, state) do
    use Ratio, comparison: true

    tracks_data =
      acc
      |> Enum.filter(fn {_pad, samples} -> not Enum.empty?(samples) end)
      |> Enum.map(fn {pad, samples} ->
        %{timescale: timescale} = ctx.pads[pad].stream_format
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
              sample_offset: Ratio.floor((sample.pts - sample.dts) / timescale)
            }
          end)

        samples_data = Enum.map_join(samples, & &1.payload)

        duration = last_sample.dts - first_sample.dts + last_sample.metadata.duration

        %{
          pad: pad,
          id: state.pad_to_track_data[pad].id,
          sequence_number: state.seq_num,
          base_timestamp:
            Helper.timescalify(state.pad_to_track_data[pad].segment_base_timestamp, timescale)
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
      independent?: is_segment_independent(acc, ctx)
    }

    buffer = %Buffer{payload: payload, metadata: metadata}

    # Update segment base timestamps for each track
    state =
      Enum.reduce(tracks_data, state, fn %{unscaled_duration: duration, pad: pad}, state ->
        update_in(state, [:pad_to_track_data, pad, :segment_base_timestamp], &(&1 + duration))
      end)
      |> Map.update!(:seq_num, &(&1 + 1))

    {buffer, state}
  end

  defp is_segment_independent(segment, ctx) do
    case find_video_pads(ctx) do
      [] ->
        true

      [video_pad] ->
        case segment do
          %{^video_pad => samples} ->
            hd(samples).metadata.mp4_payload.key_frame?

          _other ->
            true
        end
    end
  end

  defp generate_sample_flags(metadata) do
    key_frame? = metadata |> Map.get(:mp4_payload, %{}) |> Map.get(:key_frame?, true)

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
end
