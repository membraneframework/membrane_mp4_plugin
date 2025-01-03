defmodule Membrane.MP4.Demuxer.CMAF do
  @moduledoc """
  """
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SamplesInfo, as: ISOMSamplesInfo
  alias Membrane.MP4.Demuxer.CMAF.SamplesInfo, as: CMAFSamplesInfo

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
          stream_structure: {_avc, _dcr},
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
  def handle_init(_ctx, _options) do
    state = %{
      unprocessed_boxes: [],
      unprocessed_binary: <<>>,
      samples_info: nil,
      tracks_to_pad_map: nil,
      all_pads_connected?: false,
      buffered_samples: %{},
      end_of_stream?: false,
      fsm_state: :moov_reading,
      pads_linked_before_notification?: false,
      track_notifications_sent?: false,
      last_timescales: %{}
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, ctx, state) do
    {new_boxes, rest} = Container.parse!(state.unprocessed_binary <> buffer.payload)

    state = %{
      state
      | unprocessed_boxes: state.unprocessed_boxes ++ new_boxes,
        unprocessed_binary: rest
    }

    handle_new_box(ctx, state)
  end

  defp handle_new_box(_ctx, %{unprocessed_boxes: []} = state) do
    {[], state}
  end

  defp handle_new_box(ctx, state) do
    [{first_box_name, first_box} | rest_of_boxes] = state.unprocessed_boxes
    {actions, state} = do_handle_box(ctx, first_box_name, first_box, state)
    {actions, %{state | unprocessed_boxes: rest_of_boxes}}
  end

  defp do_handle_box(ctx, first_box_name, first_box, %{fsm_state: :moov_reading} = state) do
    case first_box_name do
      :ftyp ->
        {[], state}

      :moov ->
        samples_info =
          ISOMSamplesInfo.get_samples_info(
            first_box,
            0
          )
        tracks_to_pad_map = match_tracks_with_pads(ctx, samples_info) 
        actions = Enum.map(samples_info.sample_tables, fn {track_id, samples_table} -> 
          track_pad = Pad.ref(:output, Map.get(tracks_to_pad_map, track_id))
          {:stream_format, {track_pad, samples_table.sample_description}}
        end)
        state = %{state | tracks_to_pad_map: tracks_to_pad_map, fsm_state: :moof_reading}
        {actions, state}
      _other ->
        raise "Wrong FSM state"
    end
  end

  defp do_handle_box(_ctx, first_box_name, first_box, %{fsm_state: :moof_reading} = state) do
    case first_box_name do
      :sidx ->
        last_timescales = Map.put(state.last_timescales, first_box.fields.reference_id, first_box.fields.timescale)
        {[], %{state | last_timescales: last_timescales}}

      :styp ->
        {[], state}

      :moof ->
        samples_info = CMAFSamplesInfo.get_samples_info(first_box)
        {[], %{state | samples_info: samples_info, fsm_state: :mdat_reading}}

      _other ->
        raise "Wrong FSM state, #{inspect(state)}"
    end
  end

  defp do_handle_box(_ctx, first_box_name, first_box, %{fsm_state: :mdat_reading} = state) do
    case first_box_name do
      :mdat ->
        actions = read_mdat(first_box, state)
        {actions, %{state | fsm_state: :moof_reading}}

      _other ->
        raise "Wrong FSM state, #{inspect(state)}"
    end
  end

  defp read_mdat(mdat_box, state) do
    Enum.map(state.samples_info, fn sample -> 
      payload = mdat_box.content |> :erlang.binary_part(sample.offset, sample.size) 
      dts = Ratio.new(sample.ts, state.last_timescales[sample.track_id]) |> Membrane.Time.seconds()
      pts = Ratio.new((sample.ts+sample.composition_offset), state.last_timescales[sample.track_id]) |> Membrane.Time.seconds()

      {:buffer, {Pad.ref(:output, state.tracks_to_pad_map[sample.track_id]), %Membrane.Buffer{payload: payload, pts: pts, dts: dts}}}
    end)
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

  defp match_tracks_with_pads(ctx, samples_info) do
    sample_tables =
      samples_info.sample_tables
      |> reject_unsupported_sample_types()

    output_pads_data =
      ctx.pads
      |> Map.values()
      |> Enum.filter(&(&1.direction == :output))

    if length(output_pads_data) not in [0, map_size(sample_tables)] do
      raise_pads_not_matching_codecs_error!(ctx, samples_info)
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
            raise_pads_not_matching_codecs_error!(ctx, samples_info)
          end

          %{track_id => pad_data_to_pad_id(pad_data)}

        _many ->
          kind_to_pads_data = output_pads_data |> Enum.group_by(& &1.options.kind)

          kind_to_tracks =
            sample_tables
            |> reject_unsupported_sample_types()
            |> Enum.group_by(
              fn {_track_id, table} -> sample_description_to_kind(table.sample_description) end,
              fn {track_id, _table} -> track_id end
            )

          raise? =
            Enum.any?(kind_to_pads_data, fn {kind, pads} ->
              length(pads) != length(kind_to_tracks[kind])
            end)

          if raise?, do: raise_pads_not_matching_codecs_error!(ctx, samples_info)

          kind_to_tracks
          |> Enum.flat_map(fn {kind, tracks} ->
            pad_refs = kind_to_pads_data[kind] |> Enum.map(&pad_data_to_pad_id/1)
            Enum.zip(tracks, pad_refs)
          end)
          |> Map.new()
      end

    track_to_pad_id
  end

  defp pad_data_to_pad_id(%{ref: Pad.ref(_name, id)}), do: id

  @spec raise_pads_not_matching_codecs_error!(map(), map()) :: no_return()
  defp raise_pads_not_matching_codecs_error!(ctx, samples_info) do
    pads_kinds =
      ctx.pads
      |> Enum.flat_map(fn
        {:input, _pad_data} -> []
        {_pad_ref, %{options: %{kind: kind}}} -> [kind]
      end)

    tracks_codecs =
      samples_info.sample_tables
      |> reject_unsupported_sample_types()
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
      |> reject_unsupported_sample_types()
      |> Enum.map(fn {track_id, table} ->
        pad_id = state.track_to_pad_id[track_id]
        {pad_id, table.sample_description}
      end)

    [{:notify_parent, {:new_tracks, new_tracks}}]
  end

  defp get_stream_format(state) do
    state.samples_info.sample_tables
    |> reject_unsupported_sample_types()
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

    state = %{state | all_pads_connected?: all_pads_connected?}
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
    count_of_supported_tracks =
      state.samples_info.sample_tables
      |> reject_unsupported_sample_types()
      |> Enum.count()

    tracks = 1..count_of_supported_tracks

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
      Enum.flat_map(state.buffered_samples, fn {track_id, track_samples} ->
        buffers =
          track_samples
          |> Enum.reverse()
          |> Enum.map(fn {buffer, ^track_id} -> buffer end)

        pad_id = state.track_to_pad_id[track_id]

        if pad_id != nil do
          [buffer: {Pad.ref(:output, pad_id), buffers}]
        else
          []
        end
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

  defp reject_unsupported_sample_types(sample_tables) do
    Map.reject(sample_tables, fn {_track_id, table} -> table.sample_description == nil end)
  end
end
