defmodule Membrane.MP4.Demuxer.CMAF do
  @moduledoc """
  A demuxer capable of demuxing streams packed in CMAF container.
  """
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.CMAF.SamplesInfo, as: CMAFSamplesInfo
  alias Membrane.MP4.MovieBox.SampleTableBox

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
      last_timescales: %{},
      how_many_segment_bytes_read: 0,
      tracks_info: nil
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

    case state.unprocessed_boxes do
      [] ->
        {[], state}

      [{first_box_name, first_box} | rest_of_boxes] ->
        {actions, state} = handle_box(ctx, first_box_name, first_box, state)
        {actions, %{state | unprocessed_boxes: rest_of_boxes}}
    end
  end

  defp handle_box(ctx, box_name, box, %{fsm_state: :moov_reading} = state) do
    case box_name do
      :ftyp ->
        {[], state}

      :moov ->
        tracks_info = CMAFSamplesInfo.read_moov(box) |> reject_unsupported_tracks_info()
        tracks_to_pad_map = match_tracks_with_pads(ctx, tracks_info)

        state = %{
          state
          | tracks_to_pad_map: tracks_to_pad_map,
            fsm_state: :moof_reading,
            tracks_info: tracks_info
        }

        actions = get_stream_format(state) ++ maybe_get_track_notifications(state)

        {actions, state}

      _other ->
        raise "Wrong FSM state"
    end
  end

  defp handle_box(_ctx, box_name, box, %{fsm_state: :moof_reading} = state) do
    case box_name do
      :sidx ->
        last_timescales =
          Map.put(state.last_timescales, box.fields.reference_id, box.fields.timescale)

        {[], %{state | last_timescales: last_timescales}}

      :styp ->
        {[], state}

      :moof ->
        samples_info = CMAFSamplesInfo.get_samples_info(box)

        {[],
         %{
           state
           | samples_info: samples_info,
             fsm_state: :mdat_reading,
             how_many_segment_bytes_read: box.size + box.header_size
         }}

      _other ->
        raise "Wrong FSM state, #{inspect(state)}"
    end
  end

  defp handle_box(_ctx, box_name, box, %{fsm_state: :mdat_reading} = state) do
    case box_name do
      :mdat ->
        state = Map.update!(state, :how_many_segment_bytes_read, &(&1 + box.header_size))
        {actions, state} = read_mdat(box, state)
        new_fsm_state = if state.samples_info == [], do: :moof_reading, else: :mdat_reading
        {actions, %{state | fsm_state: new_fsm_state}}

      _other ->
        raise "Wrong FSM state, #{inspect(state)}"
    end
  end

  defp read_mdat(mdat_box, state) do
    {this_mdat_samples, rest_of_samples_info} =
      Enum.split_while(
        state.samples_info,
        &(&1.offset - state.how_many_segment_bytes_read < byte_size(mdat_box.content))
      )

    actions =
      Enum.map(this_mdat_samples, fn sample ->
        payload =
          mdat_box.content
          |> :erlang.binary_part(sample.offset - state.how_many_segment_bytes_read, sample.size)

        dts =
          Ratio.new(sample.ts, state.last_timescales[sample.track_id]) |> Membrane.Time.seconds()

        pts =
          Ratio.new(sample.ts + sample.composition_offset, state.last_timescales[sample.track_id])
          |> Membrane.Time.seconds()

        {:buffer,
         {Pad.ref(:output, state.tracks_to_pad_map[sample.track_id]),
          %Membrane.Buffer{payload: payload, pts: pts, dts: dts}}}
      end)

    {actions, %{state | samples_info: rest_of_samples_info}}
  end

  defp store_samples(state, samples) do
    Enum.reduce(samples, state, fn {_buffer, track_id} = sample, state ->
      samples = [sample | Map.get(state.buffered_samples, track_id, [])]
      put_in(state, [:buffered_samples, track_id], samples)
    end)
  end

  defp parse_header(data) do
    case Container.Header.parse(data) do
      {:ok, header, _rest} -> header
      {:error, :not_enough_data} -> nil
    end
  end

  defp match_tracks_with_pads(ctx, tracks_info) do
    output_pads_data =
      ctx.pads
      |> Map.values()
      |> Enum.filter(&(&1.direction == :output))

    if length(output_pads_data) not in [0, map_size(tracks_info)] do
      raise_pads_not_matching_codecs_error!(ctx, tracks_info)
    end

    track_to_pad_id =
      case output_pads_data do
        [] ->
          tracks_info
          |> Map.new(fn {track_id, _table} -> {track_id, track_id} end)

        [pad_data] ->
          {track_id, track_format} = Enum.at(tracks_info, 0)

          if pad_data.options.kind not in [
               nil,
               track_format_to_kind(track_format)
             ] do
            raise_pads_not_matching_codecs_error!(ctx, tracks_info)
          end

          %{track_id => pad_data_to_pad_id(pad_data)}

        _many ->
          kind_to_pads_data = output_pads_data |> Enum.group_by(& &1.options.kind)

          kind_to_tracks =
            tracks_info
            |> Enum.group_by(
              fn {_track_id, track_format} -> track_format_to_kind(track_format) end,
              fn {track_id, _track_format} -> track_id end
            )

          raise? =
            Enum.any?(kind_to_pads_data, fn {kind, pads} ->
              length(pads) != length(kind_to_tracks[kind])
            end)

          if raise?, do: raise_pads_not_matching_codecs_error!(ctx, tracks_info)

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
  defp raise_pads_not_matching_codecs_error!(ctx, tracks_info) do
    pads_kinds =
      ctx.pads
      |> Enum.flat_map(fn
        {:input, _pad_data} -> []
        {_pad_ref, %{options: %{kind: kind}}} -> [kind]
      end)

    tracks_codecs =
      tracks_info
      |> Enum.map(fn {_track, track_format} -> track_format.__struct__ end)

    raise """
    Pads kinds don't match with tracks codecs. Pads kinds are #{inspect(pads_kinds)}. \
    Tracks codecs are #{inspect(tracks_codecs)}
    """
  end

  defp track_format_to_kind(%Membrane.H264{}), do: :video
  defp track_format_to_kind(%Membrane.H265{}), do: :video
  defp track_format_to_kind(%Membrane.AAC{}), do: :audio
  defp track_format_to_kind(%Membrane.Opus{}), do: :audio

  defp maybe_get_track_notifications(%{pads_linked_before_notification?: true}), do: []

  defp maybe_get_track_notifications(%{pads_linked_before_notification?: false} = state) do
    new_tracks =
      state.tracks_info
      |> Enum.map(fn {track_id, track_format} ->
        pad_id = state.tracks_to_pad_map[track_id]
        {pad_id, track_format}
      end)

    [{:notify_parent, {:new_tracks, new_tracks}}]
  end

  defp get_stream_format(state) do
    state.tracks_info
    |> Enum.map(fn {track_id, track_format} ->
      pad_id = state.tracks_to_pad_map[track_id]
      {:stream_format, {Pad.ref(:output, pad_id), track_format}}
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
        |> track_format_to_kind()

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

  defp all_pads_connected?(_ctx, %{tracks_info: nil}), do: false

  defp all_pads_connected?(ctx, state) do
    count_of_supported_tracks =
      state.tracks_info
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

  defp reject_unsupported_tracks_info(tracks_info) do
    Map.reject(tracks_info, fn {_track_id, track_format} -> track_format == nil end)
  end
end
