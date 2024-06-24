defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc """
  A Membrane Element for demuxing an MP4.

  The MP4 must have `fast start` enabled, i.e. the `moov` box must precede the `mdat` box.
  Once the Demuxer identifies the tracks in the MP4, `t:new_tracks_t/0` notification is sent for each of the tracks.

  All the tracks in the MP4 must have a corresponding output pad linked (`Pad.ref(:output, track_id)`).
  """
  use Membrane.Filter

  alias Membrane.File.NewSeekEvent
  alias Membrane.{MP4, RemoteStream}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SamplesInfo

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :bytestream, content_format: content_format}
      when content_format in [nil, MP4],
    flow_control: :auto

  def_output_pad :output,
    accepted_format:
      any_of(
        %Membrane.AAC{config: {:esds, _esds}},
        %Membrane.H264{
          stream_structure: {:avc1, _dcr},
          alignment: :au
        },
        %Membrane.H265{
          stream_structure: {_hevc, _dcr},
          alignment: :au
        },
        %Membrane.Opus{self_delimiting?: false}
      ),
    availability: :on_request,
    options: [
      codec: [
        spec: Membrane.H264 | Membrane.H265 | Membrane.Opus | Membrane.AAC | nil,
        default: nil,
        description: """
        Specifies, what kind of codec can be handled by a pad.
        """
      ]
    ]

  def_options optimize_for_non_fast_start?: [
                default: false,
                spec: boolean(),
                description: """
                When set to `true`, the demuxer is optimized for working with non-fast_start MP4
                stream (that means - with a stream, in which the :moov box is put after the :mdat box)
                You might consider setting that option to `true` if the following two conditions are met:
                - you are processing large non-fast_start MP4 files
                - the source of the stream is a "seekable source" - currently the only possible
                option is to use a `Membrane.File.Source` with `seekable?: true` option.

                When set to `false`, no optimization will be performed, so in case of processing the
                non-fast_start MP4 stream, the whole content of the :mdat box will be stored in
                memory.

                Defaults to `false`.
                """
              ]

  @typedoc """
  Notification sent when the tracks are identified in the MP4.

  Upon receiving the notification, `Pad.ref(:output, track_id)` pads should be linked
  for all the `track_id` in the list.
  The `content` field contains the stream format which is contained in the track.
  """
  @type new_tracks_t() ::
          {:new_tracks, [{track_id :: integer(), content :: struct()}]}

  @header_boxes [:ftyp, :moov]

  @impl true
  def handle_init(_ctx, options) do
    state = %{
      boxes: [],
      partial: <<>>,
      samples_info: nil,
      all_pads_connected?: false,
      buffered_samples: %{},
      end_of_stream?: false,
      optimize_for_non_fast_start?: options.optimize_for_non_fast_start?,
      fsm_state: :metadata_reading,
      boxes_size: 0,
      mdat_beginning: nil,
      mdat_size: nil,
      mdat_header_size: nil,
      track_to_pad_id: %{},
      track_notifications_sent?: false
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    if state.optimize_for_non_fast_start? do
      seek(state, :bof, :infinity, false)
    else
      {[], state}
    end
  end

  @impl true
  def handle_event(:input, %NewSeekEvent{}, _ctx, %{fsm_state: :mdat_skipping} = state) do
    {[], update_fsm_state(state, :new_seek_event)}
  end

  @impl true
  def handle_event(:input, %NewSeekEvent{}, _ctx, %{fsm_state: :going_back_to_mdat} = state) do
    {[], update_fsm_state(state, :new_seek_event)}
  end

  @impl true
  def handle_event(:input, %NewSeekEvent{}, _ctx, %{optimize_for_non_fast_start?: false}) do
    raise "In order to work with a seekable source the demuxer must have the `optimize_for_non_fast_start?: true` option."
  end

  @impl true
  def handle_event(_pad, event, _context, state), do: {[forward: event], state}

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  def handle_buffer(
        :input,
        _buffer,
        _ctx,
        %{
          fsm_state: fsm_state
        } = state
      )
      when fsm_state in [:mdat_skipping, :going_back_to_mdat] do
    {[], state}
  end

  @impl true
  def handle_buffer(
        :input,
        buffer,
        _ctx,
        %{
          fsm_state: :samples_info_present_and_all_pads_connected
        } = state
      ) do
    {samples, rest, samples_info} =
      SamplesInfo.get_samples(
        state.samples_info,
        state.partial <> buffer.payload
      )

    buffers = get_buffer_actions(samples, state)

    {buffers, %{state | samples_info: samples_info, partial: rest}}
  end

  def handle_buffer(
        :input,
        buffer,
        _ctx,
        %{fsm_state: :samples_info_present} = state
      ) do
    # Until all pads are connected we are storing all the samples
    {samples, rest, samples_info} =
      SamplesInfo.get_samples(
        state.samples_info,
        state.partial <> buffer.payload
      )

    state = store_samples(state, samples)

    {[pause_auto_demand: :input], %{state | samples_info: samples_info, partial: rest}}
  end

  def handle_buffer(:input, buffer, ctx, state) do
    {new_boxes, rest} = Container.parse!(state.partial <> buffer.payload)

    state = %{
      state
      | boxes: state.boxes ++ new_boxes,
        boxes_size:
          state.boxes_size + byte_size(state.partial <> buffer.payload) - byte_size(rest)
    }

    maybe_header = parse_header(rest)

    update_fsm_state_ctx =
      if :mdat in Keyword.keys(state.boxes) or
           (maybe_header != nil and maybe_header.name == :mdat) do
        :started_parsing_mdat
      end

    state =
      set_mdat_metadata(state, update_fsm_state_ctx, maybe_header)
      |> update_fsm_state(update_fsm_state_ctx)
      |> set_partial(rest)

    cond do
      state.fsm_state == :mdat_reading ->
        handle_can_read_mdat_box(ctx, state)

      state.optimize_for_non_fast_start? ->
        handle_non_fast_start_optimization(state)

      true ->
        {[], state}
    end
  end

  defp set_mdat_metadata(state, context, maybe_header) do
    if context == :started_parsing_mdat do
      %{
        state
        | mdat_beginning: state.mdat_beginning || get_mdat_header_beginning(state.boxes),
          mdat_header_size:
            state.mdat_header_size || maybe_header[:header_size] || state.boxes[:mdat].header_size,
          mdat_size: state.mdat_size || maybe_header[:content_size] || state.boxes[:mdat].size
      }
    else
      state
    end
  end

  defp set_partial(state, rest) do
    partial = if state.fsm_state in [:skip_mdat, :go_back_to_mdat], do: <<>>, else: rest
    %{state | partial: partial}
  end

  defp update_fsm_state(state, ctx \\ nil) do
    %{state | fsm_state: do_update_fsm_state(state, ctx)}
  end

  defp do_update_fsm_state(%{fsm_state: :metadata_reading} = state, ctx) do
    all_headers_read? = Enum.all?(@header_boxes, &Keyword.has_key?(state.boxes, &1))

    cond do
      ctx == :started_parsing_mdat and all_headers_read? ->
        :mdat_reading

      ctx == :started_parsing_mdat and not all_headers_read? and
          state.optimize_for_non_fast_start? ->
        :skip_mdat

      true ->
        :metadata_reading
    end
  end

  defp do_update_fsm_state(%{fsm_state: :skip_mdat}, :seek) do
    :mdat_skipping
  end

  defp do_update_fsm_state(%{fsm_state: :mdat_skipping}, :new_seek_event) do
    :metadata_reading_continuation
  end

  defp do_update_fsm_state(%{fsm_state: :metadata_reading_continuation} = state, _ctx) do
    if Enum.all?(@header_boxes, &Keyword.has_key?(state.boxes, &1)) do
      :go_back_to_mdat
    else
      :metadata_reading_continuation
    end
  end

  defp do_update_fsm_state(%{fsm_state: :go_back_to_mdat}, :seek) do
    :going_back_to_mdat
  end

  defp do_update_fsm_state(%{fsm_state: :going_back_to_mdat}, :new_seek_event) do
    :mdat_reading
  end

  defp do_update_fsm_state(%{fsm_state: :mdat_reading} = state, _ctx) do
    if state.samples_info != nil do
      :samples_info_present
    else
      :mdat_reading
    end
  end

  defp do_update_fsm_state(%{fsm_state: :samples_info_present} = state, _ctx) do
    if state.all_pads_connected? do
      :samples_info_present_and_all_pads_connected
    else
      :samples_info_present
    end
  end

  defp do_update_fsm_state(%{fsm_state: fsm_state}, _ctx) do
    fsm_state
  end

  defp handle_non_fast_start_optimization(%{fsm_state: :skip_mdat} = state) do
    box_after_mdat_beginning = state.mdat_beginning + state.mdat_header_size + state.mdat_size
    seek(state, box_after_mdat_beginning, :infinity, false)
  end

  defp handle_non_fast_start_optimization(%{fsm_state: :go_back_to_mdat} = state) do
    seek(
      state,
      state.mdat_beginning,
      state.mdat_size + state.mdat_header_size,
      false
    )
  end

  defp handle_non_fast_start_optimization(state) do
    {[], state}
  end

  defp seek(state, start, size_to_read, last?) do
    state = update_fsm_state(state, :seek)

    {[
       event:
         {:input,
          %Membrane.File.SeekSourceEvent{start: start, size_to_read: size_to_read, last?: last?}}
     ], state}
  end

  defp handle_can_read_mdat_box(ctx, state) do
    {seek_events, state} =
      if state.optimize_for_non_fast_start? do
        # there will be no more skips,
        # so with `optimize_for_non_fast_start?: true`
        # we need to send SourceSeekEvent to indicate
        # that we want to receive `:end_of_stream`
        seek(state, :cur, :infinity, true)
      else
        {[], state}
      end

    state =
      %{
        state
        | samples_info:
            SamplesInfo.get_samples_info(
              state.boxes[:moov],
              state.mdat_beginning + state.mdat_header_size
            )
      }
      |> update_fsm_state()

    # Parse the data we received so far (partial or the whole mdat box in a single buffer) and
    # either store or send the data (if all pads are connected)
    mdat_header_size = state.mdat_header_size

    data =
      if Keyword.has_key?(state.boxes, :mdat) do
        state.boxes[:mdat].content
      else
        <<_header::binary-size(mdat_header_size), content::binary>> = state.partial
        content
      end

    {samples, rest, samples_info} =
      SamplesInfo.get_samples(state.samples_info, data)

    state = %{state | samples_info: samples_info, partial: rest}

    state = match_tracks_with_pads(ctx, state)

    all_pads_connected? = all_pads_connected?(ctx, state)

    {buffers, state} =
      if all_pads_connected? do
        {get_buffer_actions(samples, state), state}
      else
        {[], store_samples(state, samples)}
      end

    notifications = get_track_notifications(state)

    stream_format = if all_pads_connected?, do: get_stream_format(state), else: []

    state =
      %{
        state
        | all_pads_connected?: all_pads_connected?,
          track_notifications_sent?: true
      }
      |> update_fsm_state()

    {seek_events ++ notifications ++ stream_format ++ buffers, state}
  end

  defp store_samples(state, samples) do
    Enum.reduce(samples, state, fn {_buffer, track_id} = sample, state ->
      samples = [sample | Map.get(state.buffered_samples, track_id, [])]
      put_in(state, [:buffered_samples, track_id], samples)
    end)
  end

  defp get_buffer_actions(samples, state) do
    Enum.map(samples, fn {buffer, track_id} ->
      pad_id = state.track_to_pad_id[track_id]
      {:buffer, {Pad.ref(:output, pad_id), buffer}}
    end)
  end

  defp parse_header(data) do
    case Container.Header.parse(data) do
      {:ok, header, _rest} -> header
      {:error, :not_enough_data} -> nil
    end
  end

  defp match_tracks_with_pads(ctx, state) do
    codec_to_pads_data =
      ctx.pads
      |> Map.values()
      |> Enum.reject(fn %{ref: pad_ref} -> pad_ref == :input end)
      |> Enum.group_by(& &1.options.codec)

    {track_to_pad_id, empty_codec_to_pads_data} =
      state.samples_info.sample_tables
      |> Enum.map_reduce(codec_to_pads_data, fn {track_id, table}, codec_to_pads_data ->
        %track_codec{} = table.sample_description

        case codec_to_pads_data[track_codec] do
          [pad_data | tail] ->
            codec_to_pads_data = Map.put(codec_to_pads_data, track_codec, tail)
            Pad.ref(:output, pad_id) = pad_data.ref
            {{track_id, pad_id}, codec_to_pads_data}

          _no_pad ->
            {{track_id, nil}, codec_to_pads_data}
        end
      end)

    max_pad_id =
      track_to_pad_id
      |> Enum.flat_map(fn {_track, pad_id} -> if pad_id != nil, do: [pad_id], else: [] end)
      |> Enum.max(&>=/2, fn -> 0 end)

    {track_to_pad_id, _max_pad_id} =
      track_to_pad_id
      |> Enum.map_reduce(max_pad_id, fn
        {track_id, nil}, max_pad_id -> {{track_id, max_pad_id + 1}, max_pad_id + 1}
        track_pad_pair, max_pad_id -> {track_pad_pair, max_pad_id}
      end)

    raise? =
      empty_codec_to_pads_data
      |> Map.values()
      |> Enum.any?(&(&1 != []))

    if raise? do
      "dupaaaa"
    end

    %{state | track_to_pad_id: Map.new(track_to_pad_id)}
  end

  defp get_track_notifications(state) do
    new_tracks =
      state.samples_info.sample_tables
      |> Enum.map(fn {track_id, table} ->
        pad_id = state.track_to_pad_id[track_id]
        {pad_id, table.sample_description}
      end)

    [{:notify_parent, {:new_tracks, new_tracks}}]
  end

  defp get_stream_format(state) do
    state.samples_info.sample_tables
    |> Enum.map(fn {track_id, table} ->
      pad_id = state.track_to_pad_id[track_id]
      {:stream_format, {Pad.ref(:output, pad_id), table.sample_description}}
    end)
  end

  @impl true
  def handle_pad_added(:input, _ctx, state) do
    {[], state}
  end

  def handle_pad_added(_pad, _ctx, %{all_pads_connected?: true}) do
    raise "All tracks have corresponding pad already connected"
  end

  def handle_pad_added(Pad.ref(:output, _track_id) = pad_ref, ctx, state) do
    :ok = validate_pad_codec!(pad_ref, ctx.pad_options.codec, ctx, state)
    all_pads_connected? = all_pads_connected?(ctx, state)

    {actions, state} =
      if all_pads_connected? do
        {buffer_actions, state} = flush_samples(state)
        maybe_stream_format = if state.samples_info != nil, do: get_stream_format(state), else: []
        maybe_eos = if state.end_of_stream?, do: get_end_of_stream_actions(ctx), else: []

        {maybe_stream_format ++ buffer_actions ++ [resume_auto_demand: :input] ++ maybe_eos,
         state}
      else
        {[], state}
      end

    state = %{state | all_pads_connected?: all_pads_connected?} |> update_fsm_state()
    {actions, state}
  end

  defp validate_pad_codec!(pad_ref, pad_codec, ctx, state) do
    allowed_codecs = [nil, Membrane.H264, Membrane.H265, Membrane.Opus, Membrane.AAC]

    if pad_codec not in allowed_codecs do
      raise """
      Pad #{inspect(pad_ref)} has :codec option set to #{inspect(pad_codec)}, while it has te be one of \
      #{List.delete(allowed_codecs, nil) |> inspect()} or be unspecified.
      """
    end

    if not state.track_notifications_sent? and
         Enum.count(ctx.pads, &match?({Pad.ref(:output, _id), %{options: %{codec: nil}}}, &1)) > 1 do
      raise """
      If pads are linked before :new_tracks notifications and there are more then one of them, pad option \
      :codec has to be specyfied.
      """
    end

    if state.track_notifications_sent? do
      Pad.ref(:output, pad_id) = pad_ref

      related_track =
        state.track_to_pad_id
        |> Map.keys()
        |> Enum.find(&(state.track_to_pad_id[&1] == pad_id))

      if related_track == nil do
        raise """
        Pad #{inspect(pad_ref)} doesn't have a related track. If you link pads after #{inspect(__MODULE__)} \
        sent the track notification, you have to restrict yourself to the pad occuring in this notification. \
        Tracks, that occured in this notification are: #{Map.keys(state.track_to_pad_id) |> inspect()}
        """
      end

      track_codec = state.samples_info.sample_tables[related_track].sample_description

      if pad_codec != nil and track_codec != pad_codec do
        raise """
        Pad option :codec must point on the related track codec or be equal nil, but pad #{inspect(pad_ref)} \
        codec is #{inspect(pad_codec)}, while the related track codec is #{inspect(track_codec)}
        """
      end
    end

    :ok
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{all_pads_connected?: false} = state) do
    {[], %{state | end_of_stream?: true}}
  end

  def handle_end_of_stream(:input, ctx, %{all_pads_connected?: true} = state) do
    {get_end_of_stream_actions(ctx), state}
  end

  defp all_pads_connected?(_ctx, %{samples_info: nil}), do: false

  defp all_pads_connected?(ctx, state) do
    tracks = 1..state.samples_info.tracks_number

    pads =
      ctx.pads
      |> Enum.flat_map(fn
        {Pad.ref(:output, pad_id), _data} -> [pad_id]
        _pad -> []
      end)

    Range.size(tracks) == length(pads)
  end

  defp flush_samples(state) do
    actions =
      Enum.map(state.buffered_samples, fn {track_id, track_samples} ->
        buffers =
          track_samples
          |> Enum.reverse()
          |> Enum.map(fn {buffer, ^track_id} -> buffer end)

        pad_id = state.track_to_pad_id[track_id]
        {:buffer, {Pad.ref(:output, pad_id), buffers}}
      end)

    state = %{state | buffered_samples: %{}}
    {actions, state}
  end

  defp get_end_of_stream_actions(ctx) do
    Enum.filter(ctx.pads, &match?({Pad.ref(:output, _id), _data}, &1))
    |> Enum.map(fn {pad_ref, _data} ->
      {:end_of_stream, pad_ref}
    end)
  end

  defp get_mdat_header_beginning([]) do
    0
  end

  defp get_mdat_header_beginning([{:mdat, _box} | _rest]) do
    0
  end

  defp get_mdat_header_beginning([{_other_name, box} | rest]) do
    box.header_size + box.size + get_mdat_header_beginning(rest)
  end
end
