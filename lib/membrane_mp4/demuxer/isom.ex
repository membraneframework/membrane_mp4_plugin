defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc """
  A Membrane Element for demuxing an MP4.

  The MP4 must have `fast start` enabled, i.e. the `moov` box must precede the `mdat` box.
  Once the Demuxer identifies the tracks in the MP4, `t:new_tracks_t/0` notification is sent for each of the tracks.

  All pads has to be linked either before `handle_playing/2` callback or after the Element sends `{:new_tracks, ...}`
  notification.

  Number of pads has to be equal to the number of demuxed tracks.

  If the demuxed data contains only one track, linked pad doesn't have to specify `:kind` option.

  If there are more than one track and pads are linked before `handle_playing/2`, every pad has to specify `:kind`
  option.

  If any of pads isn't linked before `handle_playing/2`, #{inspect(__MODULE__)} will send `{:new_tracks, ...}`
  notification to the parent. Otherwise, if any of them is linked before `handle_playing/3`, this notification won't
  be sent.

  If pads are linked after the `{:new_tracks, ...}` notfitaction, their references must match MP4 tracks ids
  (`Pad.ref(:output, track_id)`).
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
      kind: [
        spec: :video | :audio | nil,
        default: nil,
        description: """
        Specifies, what kind of data can be handled by a pad.
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
      track_notifications_sent?: false,
      pads_linked_before_notification?: false
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

    notifications = maybe_get_track_notifications(state)

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
    sample_tables = state.samples_info.sample_tables

    output_pads_data =
      ctx.pads
      |> Map.values()
      |> Enum.reject(fn %{ref: pad_ref} -> pad_ref == :input end)

    if length(output_pads_data) not in [0, map_size(sample_tables)] do
      raise_pads_not_matching_codecs_error!(ctx, state)
    end

    track_to_pad_id =
      case output_pads_data do
        [] ->
          sample_tables
          |> Map.new(fn {track_id, _table} -> {track_id, track_id} end)

        [pad_data] ->
          {track_id, table} = Enum.at(sample_tables, 0)

          if pad_data.options.kind not in [
               nil,
               sample_description_to_kind(table.sample_description)
             ] do
            raise_pads_not_matching_codecs_error!(ctx, state)
          end

          %{track_id => pad_data_to_pad_id(pad_data)}

        _many ->
          kind_to_pads_data = output_pads_data |> Enum.group_by(& &1.options.kind)

          kind_to_tracks =
            sample_tables
            |> Enum.group_by(
              fn {_track_id, table} -> sample_description_to_kind(table.sample_description) end,
              fn {track_id, _table} -> track_id end
            )

          raise? =
            Enum.any?(kind_to_pads_data, fn {kind, pads} ->
              length(pads) != length(kind_to_tracks[kind])
            end)

          if raise?, do: raise_pads_not_matching_codecs_error!(ctx, state)

          kind_to_tracks
          |> Enum.flat_map(fn {kind, tracks} ->
            pad_refs = kind_to_pads_data[kind] |> Enum.map(&pad_data_to_pad_id/1)
            Enum.zip(tracks, pad_refs)
          end)
          |> Map.new()
      end

    %{state | track_to_pad_id: Map.new(track_to_pad_id)}
  end

  defp pad_data_to_pad_id(%{ref: Pad.ref(_name, id)}), do: id

  @spec raise_pads_not_matching_codecs_error!(map(), map()) :: no_return()
  defp raise_pads_not_matching_codecs_error!(ctx, state) do
    pads_kinds =
      ctx.pads
      |> Enum.flat_map(fn
        {:input, _pad_data} -> []
        {_pad_ref, %{options: %{kind: kind}}} -> [kind]
      end)

    tracks_codecs =
      state.samples_info.sample_tables
      |> Enum.map(fn {_track, table} -> table.sample_description.__struct__ end)

    raise """
    Pads kinds don't match with tracks codecs. Pads kinds are #{inspect(pads_kinds)}. \
    Tracks codecs are #{inspect(tracks_codecs)}
    """
  end

  defp sample_description_to_kind(%Membrane.H264{}), do: :video
  defp sample_description_to_kind(%Membrane.H265{}), do: :video
  defp sample_description_to_kind(%Membrane.AAC{}), do: :audio
  defp sample_description_to_kind(%Membrane.Opus{}), do: :audio

  defp maybe_get_track_notifications(%{pads_linked_before_notification?: true}), do: []

  defp maybe_get_track_notifications(%{pads_linked_before_notification?: false} = state) do
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
    state =
      case ctx.playback do
        :stopped ->
          %{state | pads_linked_before_notification?: true}

        :playing when state.track_notifications_sent? ->
          state

        :playing ->
          raise """
          Pads can be linked either before #{inspect(__MODULE__)} enters :playing playback or after it \
          sends {:new_tracks, ...} notification
          """
      end

    :ok = validate_pad_kind!(pad_ref, ctx.pad_options.kind, ctx, state)
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

  defp validate_pad_kind!(pad_ref, pad_kind, ctx, state) do
    allowed_kinds = [nil, :audio, :video]

    if pad_kind not in allowed_kinds do
      raise """
      Pad #{inspect(pad_ref)} has :kind option set to #{inspect(pad_kind)}, while it has te be one of \
      #{[:audio, :video] |> inspect()} or be unspecified.
      """
    end

    if not state.track_notifications_sent? and
         Enum.count(ctx.pads, &match?({Pad.ref(:output, _id), %{options: %{kind: nil}}}, &1)) > 1 do
      raise """
      If pads are linked before :new_tracks notifications and there are more then one of them, pad option \
      :kind has to be specyfied.
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

      track_kind =
        state.samples_info.sample_tables[related_track].sample_description
        |> sample_description_to_kind()

      if pad_kind != nil and pad_kind != track_kind do
        raise """
        Pad option :kind must match with the kind of the related track or be equal nil, but pad #{inspect(pad_ref)} \
        kind is #{inspect(pad_kind)}, while the related track kind is #{inspect(track_kind)}
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
