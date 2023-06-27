defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc """
  A Membrane Element for demuxing an MP4.

  The MP4 must have `fast start` enabled, i.e. the `moov` box must precede the `mdat` box.
  Once the Demuxer identifies the tracks in the MP4, `t:new_tracks_t/0` notification is sent for each of the tracks.

  All the tracks in the MP4 must have a corresponding output pad linked (`Pad.ref(:output, track_id)`).
  """
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SamplesInfo

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :bytestream, content_format: content_format}
      when content_format in [nil, MP4],
    demand_unit: :buffers

  def_output_pad :output,
    accepted_format: Membrane.MP4.Payload,
    availability: :on_request

  def_options optimize_for_non_fast_start?: [default: false]

  @typedoc """
  Notification sent when the tracks are identified in the MP4.

  Upon receiving the notification, `Pad.ref(:output, track_id)` pads should be linked
  for all the `track_id` in the list.
  The `content` field describes the kind of `Membrane.MP4.Payload` which is contained in the track.
  """
  @type new_tracks_t() ::
          {:new_tracks, [{track_id :: integer(), content :: struct()}]}

  @header_boxes [:ftyp, :moov]
  @header_size 8

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
      should_drop?: options.optimize_for_non_fast_start?,
      boxes_size: 0,
      mdat_beginning: nil,
      mdat_size: nil,
      # Question for reviewers - how should this field be called?
      fsm_state: :searching_for_metadata
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    actions =
      [demand: :input] ++
        if state.optimize_for_non_fast_start? do
          [event: {:input, %Membrane.File.SeekSourceEvent{start: :bof, size_to_read: :infinity}}]
        else
          []
        end

    {actions, state}
  end

  @impl true
  def handle_event(
        :input,
        %Membrane.File.NewSeekEvent{},
        _ctx,
        %{optimize_for_non_fast_start?: true, should_drop?: true} = state
      ) do
    {[], %{state | should_drop?: false}}
  end

  @impl true
  def handle_event(
        :input,
        %Membrane.File.NewSeekEvent{},
        _ctx,
        %{optimize_for_non_fast_start?: false}
      ) do
    raise "In order to work with a seekable source the demuxer must have the `optimize_for_non_fast_start?: true` option."
  end

  @impl true
  def handle_event(_pad, event, _context, state), do: {[forward: event], state}

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_demand(
        Pad.ref(:output, _track_id),
        _size,
        :buffers,
        _ctx,
        %{all_pads_connected?: false} = state
      ) do
    {[], state}
  end

  @impl true
  def handle_demand(
        Pad.ref(:output, _track_id),
        _size,
        :buffers,
        ctx,
        %{all_pads_connected?: true} = state
      ) do
    size =
      Map.values(ctx.pads)
      |> Enum.filter(&(&1.direction == :output))
      |> Enum.map(& &1.demand_snapshot)
      |> Enum.max()

    {[demand: {:input, size}], state}
  end

  def handle_process(
        :input,
        _buffer,
        _ctx,
        %{
          optimize_for_non_fast_start?: true,
          should_drop?: true
        } = state
      ) do
    {[demand: :input], state}
  end

  # We are assuming, that after header boxes ([:ftyp, :moov]), there is a single
  # mdat box, which contains all the data
  @impl true
  def handle_process(
        :input,
        buffer,
        ctx,
        %{
          all_pads_connected?: true,
          samples_info: %SamplesInfo{}
        } = state
      ) do
    {samples, rest, samples_info} =
      SamplesInfo.get_samples(state.samples_info, state.partial <> buffer.payload)

    buffers = get_buffer_actions(samples)

    redemands =
      ctx.pads
      |> Enum.filter(fn {pad, _pad_data} -> match?(Pad.ref(:output, _ref), pad) end)
      |> Enum.flat_map(fn {pad, _pad_data} -> [redemand: pad] end)

    {buffers ++ redemands, %{state | samples_info: samples_info, partial: rest}}
  end

  def handle_process(
        :input,
        buffer,
        _ctx,
        %{all_pads_connected?: false, samples_info: %SamplesInfo{}} = state
      ) do
    # Until all pads are connected we are storing all the samples
    {samples, rest, samples_info} =
      SamplesInfo.get_samples(state.samples_info, state.partial <> buffer.payload)

    state = store_samples(state, samples)

    {[], %{state | samples_info: samples_info, partial: rest}}
  end

  def handle_process(:input, buffer, ctx, %{samples_info: nil} = state) do
    {new_boxes, rest} = Container.parse!(state.partial <> buffer.payload)

    state = %{
      state
      | boxes: state.boxes ++ new_boxes,
        boxes_size:
          state.boxes_size + byte_size(state.partial <> buffer.payload) - byte_size(rest)
    }

    maybe_header = parse_header(rest)

    started_parsing_mdat? =
      case maybe_header do
        nil -> false
        header -> header.name == :mdat
      end

    fsm_state = update_fsm_state(state, started_parsing_mdat?: started_parsing_mdat?)
    partial = if fsm_state in [:skip_mdat, :go_back_to_mdat] , do: <<>>, else: rest
    state = %{state | fsm_state: fsm_state, partial: partial}

    cond do
      fsm_state == :parsing_mdat ->
        handle_can_read_mdat_box(ctx, state)

      state.optimize_for_non_fast_start? ->
        state =
          if state.fsm_state == :skip_mdat,
            do: %{state | mdat_beginning: state.boxes_size, mdat_size: maybe_header.content_size},
            else: state

        handle_non_fast_start_optimization(state)

      true ->
        {[demand: :input], state}
    end
  end

  defp update_fsm_state(%{fsm_state: :searching_for_metadata} = state, context) do
    cond do
      Enum.all?(@header_boxes, &Keyword.has_key?(state.boxes, &1)) ->
        update_fsm_state(%{state | fsm_state: :searching_for_mdat}, context)

      Keyword.get(context, :started_parsing_mdat?, false) and state.optimize_for_non_fast_start? ->
        :skip_mdat

      true ->
        :searching_for_metadata
    end
  end

  defp update_fsm_state(%{fsm_state: :skip_mdat} = state, context) do
    if Keyword.get(context, :seeked?, false) do
      update_fsm_state(%{state | fsm_state: :continue_searching_for_metadata}, context)
    else
      :skip_mdat
    end
  end

  defp update_fsm_state(%{fsm_state: :continue_searching_for_metadata} = state, _context) do
    if Enum.all?(@header_boxes, &Keyword.has_key?(state.boxes, &1)) do
      :go_back_to_mdat
    else
      :continue_searching_for_metadata
    end
  end

  defp update_fsm_state(%{fsm_state: :go_back_to_mdat} = state, context) do
    if Keyword.get(context, :seeked?, false) do
      update_fsm_state(%{state | fsm_state: :searching_for_mdat}, context)
    else
      :go_back_to_mdat
    end
  end

  defp update_fsm_state(%{fsm_state: :searching_for_mdat} = state, context) do
    if Keyword.get(context, :started_parsing_mdat?, false) or :mdat in Keyword.keys(state.boxes) do
      :parsing_mdat
    else
      :searching_for_mdat
    end
  end

  defp update_fsm_state(%{fsm_state: :parsing_mdat}, _context) do
    :parsing_mdat
  end

  defp handle_non_fast_start_optimization(%{fsm_state: :skip_mdat} = state) do
    box_after_mdat_beginning = state.mdat_beginning + @header_size + state.mdat_size
    seek(state, box_after_mdat_beginning, :infinity, false)
  end

  defp handle_non_fast_start_optimization(%{fsm_state: fsm_state} = state)
       when fsm_state in [
              :searching_for_metadata,
              :continue_searching_for_metadata,
              :searching_for_mdat
            ] do
    {[demand: :input], state}
  end

  defp handle_non_fast_start_optimization(%{fsm_state: :go_back_to_mdat} = state) do
    seek(state, state.mdat_beginning, state.mdat_size + @header_size, true)
  end

  defp seek(state, start, size_to_read, last?) do
    state = %{
      state
      | should_drop?: true,
        fsm_state: update_fsm_state(state, seeked?: true)
    }

    {[
       event:
         {:input,
          %Membrane.File.SeekSourceEvent{start: start, size_to_read: size_to_read, last?: last?}},
       demand: :input
     ], state}
  end

  defp handle_can_read_mdat_box(ctx, state) do
    state = %{state | samples_info: SamplesInfo.get_samples_info(state.boxes[:moov])}

    # Parse the data we received so far (partial or the whole mdat box in a single buffer) and
    # either store or send the data (if all pads are connected)

    data =
      if Keyword.has_key?(state.boxes, :mdat) do
        state.boxes[:mdat].content
      else
        <<_header::binary-size(@header_size), content::binary>> = state.partial
        content
      end

    {samples, rest, samples_info} = SamplesInfo.get_samples(state.samples_info, data)
    state = %{state | samples_info: samples_info, partial: rest}

    all_pads_connected? = all_pads_connected?(ctx, state)

    {buffers, state} =
      if all_pads_connected? do
        {get_buffer_actions(samples), state}
      else
        {[], store_samples(state, samples)}
      end

    redemands =
      ctx.pads
      |> Enum.filter(fn {pad, _pad_data} -> match?(Pad.ref(:output, _ref), pad) end)
      |> Enum.flat_map(fn {pad, _pad_data} -> [redemand: pad] end)

    notifications = get_track_notifications(state)
    stream_format = if all_pads_connected?, do: get_stream_format(state), else: []

    {notifications ++ stream_format ++ buffers ++ redemands,
     %{state | all_pads_connected?: all_pads_connected?}}
  end

  defp store_samples(state, samples) do
    Enum.reduce(samples, state, fn {_buffer, track_id} = sample, state ->
      samples = [sample | Map.get(state.buffered_samples, track_id, [])]
      put_in(state, [:buffered_samples, track_id], samples)
    end)
  end

  defp get_buffer_actions(samples) do
    Enum.map(samples, fn {buffer, track_id} ->
      {:buffer, {Pad.ref(:output, track_id), buffer}}
    end)
  end

  defp parse_header(data) do
    case Container.Header.parse(data) do
      {:ok, header, _rest} -> header
      {:error, :not_enough_data} -> nil
    end
  end

  defp get_track_notifications(state) do
    new_tracks =
      state.samples_info.sample_tables
      |> Enum.map(fn {track_id, table} ->
        content = table.sample_description.content
        {track_id, content}
      end)

    [{:notify_parent, {:new_tracks, new_tracks}}]
  end

  defp get_stream_format(state) do
    state.samples_info.sample_tables
    |> Enum.map(fn {track_id, table} ->
      stream_format = %Membrane.MP4.Payload{
        content: table.sample_description.content,
        timescale: table.timescale,
        height: table.sample_description.height,
        width: table.sample_description.width
      }

      {:stream_format, {Pad.ref(:output, track_id), stream_format}}
    end)
  end

  @impl true
  def handle_pad_added(:input, _ctx, state) do
    {[], state}
  end

  def handle_pad_added(_pad, _ctx, %{all_pads_connected?: true}) do
    raise "All tracks have corresponding pad already connected"
  end

  def handle_pad_added(Pad.ref(:output, track_id), ctx, state) do
    all_pads_connected? = all_pads_connected?(ctx, state)

    {actions, state} =
      if all_pads_connected? do
        {buffer_actions, state} = flush_samples(state, track_id)
        maybe_stream_format = if state.samples_info != nil, do: get_stream_format(state), else: []
        maybe_eos = if state.end_of_stream?, do: get_end_of_stream_actions(ctx), else: []

        {maybe_stream_format ++ buffer_actions ++ maybe_eos, state}
      else
        {[], state}
      end

    {actions, %{state | all_pads_connected?: all_pads_connected?}}
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

    Enum.each(pads, fn pad ->
      if pad not in tracks do
        raise "An output pad connected with #{pad} id, however no matching track exists"
      end
    end)

    Range.size(tracks) == length(pads)
  end

  defp flush_samples(state, track_id) do
    buffers =
      Map.get(state.buffered_samples, track_id, [])
      |> Enum.reverse()
      |> Enum.map(fn {buffer, ^track_id} -> buffer end)

    actions = [buffer: {Pad.ref(:output, track_id), buffers}]

    {actions, put_in(state, [:buffered_samples, track_id], [])}
  end

  defp get_end_of_stream_actions(ctx) do
    Enum.filter(ctx.pads, &match?({Pad.ref(:output, _id), _data}, &1))
    |> Enum.map(fn {pad_ref, _data} ->
      {:end_of_stream, pad_ref}
    end)
  end
end
