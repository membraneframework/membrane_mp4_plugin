defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc """
  A Membrane Element for demuxing an MP4.

  The MP4 must have `fast start` enabled, i.e. the `moov` box must precede the `mdat` box.
  Once the Demuxer identifies the tracks in the MP4, `t:new_track_t/0` notification is sent for each of the tracks.

  All the tracks in the MP4 must have a corresponding output pad linked (`Pad.ref(:output, track_id)`).
  """
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SampleData

  def_input_pad :input,
    caps: {RemoteStream, type: :bytestream, content_format: one_of([nil, MP4])},
    demand_unit: :buffers

  def_output_pad :output,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  @typedoc """
  Notification sent when a new track is identified in the MP4.

  Upon receiving the notification a `Pad.ref(:output, track_id)` pad should be linked.
  The `content` field describes the kind of `Membrane.MP4.Payload` which is contained in the track.
  """
  @type new_track_t() ::
          {:new_track, track_id :: integer(), content :: struct()}

  @header_boxes [:ftyp, :moov]
  @mdat_header_size 8

  @impl true
  def handle_init(_options) do
    state = %{
      boxes: [],
      last_box_header: nil,
      partial: <<>>,
      sample_data: nil,
      all_pads_connected?: false,
      buffered_samples: %{},
      end_of_stream?: false
    }

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(
        Pad.ref(:output, _track_id),
        _size,
        :buffers,
        _ctx,
        %{all_pads_connected?: false} = state
      ) do
    {:ok, state}
  end

  @impl true
  def handle_demand(
        Pad.ref(:output, _track_id),
        _size,
        :buffers,
        ctx,
        %{all_pads_connected?: true} = state
      ) do
    {_pad, %{demand: size}} =
      Enum.max_by(ctx.pads, fn {_pad, pad_data} -> pad_data.demand end, fn -> 0 end)

    {{:ok, [demand: {:input, size}]}, state}
  end

  # We are assuming, that after header boxes ([:ftyp, :moov]), there is a single
  # mdat box, which contains all the data
  @impl true
  def handle_process(
        :input,
        buffer,
        _ctx,
        %{all_pads_connected?: true, sample_data: %SampleData{}} = state
      ) do
    {samples, rest, sample_data} =
      SampleData.get_samples(state.sample_data, state.partial <> buffer.payload)

    actions = get_buffer_actions(samples)

    {{:ok, actions}, %{state | sample_data: sample_data, partial: rest}}
  end

  def handle_process(
        :input,
        buffer,
        _ctx,
        %{all_pads_connected?: false, sample_data: %SampleData{}} = state
      ) do
    # Until all pads are connected we are storing all the samples
    {samples, rest, sample_data} =
      SampleData.get_samples(state.sample_data, state.partial <> buffer.payload)

    state = store_samples(state, samples)

    {:ok, %{state | sample_data: sample_data, partial: rest}}
  end

  def handle_process(:input, buffer, ctx, %{sample_data: nil} = state) do
    # Parse the boxes we have received
    {boxes, rest} = Container.parse!(state.partial <> buffer.payload)
    boxes = state.boxes ++ boxes

    state = %{state | boxes: boxes, partial: rest, last_box_header: parse_header(rest)}

    {actions, state} =
      if can_read_data_box?(state) do
        handle_can_read_mdat_box(ctx, state)
      else
        {[demand: :input], state}
      end

    {{:ok, actions}, state}
  end

  defp handle_can_read_mdat_box(ctx, state) do
    state = %{state | sample_data: SampleData.get_sample_data(state.boxes[:moov])}

    # Parse the data we received so far (partial or the whole mdat box in a single buffer) and
    # either store or send the data (if all pads are connected)

    data =
      cond do
        Keyword.has_key?(state.boxes, :mdat) ->
          state.boxes[:mdat].content

        state.last_box_header != nil and state.last_box_header.name == :mdat ->
          <<_header::binary-size(@mdat_header_size), content::binary>> = state.partial
          content

        true ->
          <<>>
      end

    {samples, rest, sample_data} = SampleData.get_samples(state.sample_data, data)
    state = %{state | sample_data: sample_data, partial: rest}

    all_pads_connected? = all_pads_connected?(ctx, state)

    {buffers, state} =
      if all_pads_connected? do
        {get_buffer_actions(samples), state}
      else
        {[], store_samples(state, samples)}
      end

    redemand =
      Enum.find_value(ctx.pads, [], fn {pad, _pad_data} ->
        case pad do
          Pad.ref(:output, _ref) -> [redemand: pad]
          :input -> false
        end
      end)

    notifications = get_track_notifications(state)
    caps = if all_pads_connected?, do: get_caps(state), else: []

    {notifications ++ caps ++ buffers ++ redemand,
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

  defp can_read_data_box?(state) do
    Enum.all?(@header_boxes, &Keyword.has_key?(state.boxes, &1)) and
      ((state.last_box_header != nil and state.last_box_header.name == :mdat) or
         Keyword.has_key?(state.boxes, :mdat))
  end

  defp get_track_notifications(state) do
    state.sample_data.sample_tables
    |> Enum.map(fn {track_id, table} ->
      content = table.sample_description.content
      {:notify, {:new_track, track_id, content}}
    end)
  end

  defp get_caps(state) do
    state.sample_data.sample_tables
    |> Enum.map(fn {track_id, table} ->
      caps = %Membrane.MP4.Payload{
        content: table.sample_description.content,
        timescale: table.timescale,
        height: table.sample_description.height,
        width: table.sample_description.width
      }

      {:caps, {Pad.ref(:output, track_id), caps}}
    end)
  end

  @impl true
  def handle_pad_added(:input, _ctx, state) do
    {:ok, state}
  end

  def handle_pad_added(_pad, _ctx, %{all_pads_connected?: true}) do
    raise "All tracks have corresponding pad already connected"
  end

  def handle_pad_added(Pad.ref(:output, track_id), ctx, state) do
    all_pads_connected? = all_pads_connected?(ctx, state)

    {actions, state} =
      if all_pads_connected? do
        {buffer_actions, state} = flush_samples(state, track_id)
        maybe_caps = if state.sample_data != nil, do: get_caps(state), else: []
        maybe_eos = if state.end_of_stream?, do: get_end_of_stream_actions(ctx), else: []

        {maybe_caps ++ buffer_actions ++ maybe_eos, state}
      else
        {[], state}
      end

    {{:ok, actions}, %{state | all_pads_connected?: all_pads_connected?}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{all_pads_connected?: false} = state) do
    {:ok, %{state | end_of_stream?: true}}
  end

  def handle_end_of_stream(:input, ctx, %{all_pads_connected?: true} = state) do
    {{:ok, get_end_of_stream_actions(ctx)}, state}
  end

  defp all_pads_connected?(_ctx, %{sample_data: nil}), do: false

  defp all_pads_connected?(ctx, state) do
    tracks = 1..state.sample_data.tracks_number

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
