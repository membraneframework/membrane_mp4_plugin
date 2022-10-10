defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc """
  asdfasdf
  """
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SampleHelper
  alias Membrane.MP4.MovieBox.SampleTableBox

  def_input_pad :input,
    caps: {RemoteStream, type: :bytestream, content_format: one_of([nil, MP4])},
    demand_unit: :buffers

  def_output_pad :output,
    caps: Membrane.MP4.Payload,
    availability: :on_request

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
  def handle_demand(Pad.ref(:output, _track_id), size, :buffers, _ctx, state) do
    actions = if state.all_pads_connected?, do: [demand: {:input, size}], else: []
    {{:ok, actions}, state}
  end

  @impl true
  # We are assuming, that after header boxes ([:ftyp, :moov]), there is a single
  # mdat box, which contains all the data
  def handle_process(
        :input,
        buffer,
        _ctx,
        %{all_pads_connected?: true, sample_data: %SampleHelper{}} = state
      ) do
    # Parse the incoming buffer - if it contains enough data,
    # send it IF the corresponding pad is connected
    # otherwise buffer the data and wait until the pad is connected

    {samples, rest, sample_data} =
      SampleHelper.get_samples(state.sample_data, state.partial <> buffer.payload)

    actions = get_buffer_actions(samples)

    {{:ok, actions}, %{state | sample_data: sample_data, partial: rest}}
  end

  def handle_process(
        :input,
        buffer,
        _ctx,
        %{all_pads_connected?: false, sample_data: %SampleHelper{}} = state
      ) do
    # store samples

    {samples, rest, sample_data} =
      SampleHelper.get_samples(state.sample_data, state.partial <> buffer.payload)

    state = store_samples(state, samples)

    {:ok, %{state | sample_data: sample_data, partial: rest}}
  end

  def handle_process(:input, buffer, ctx, %{sample_data: nil} = state) do
    # parse the boxes we have received
    {boxes, rest} = Container.parse!(state.partial <> buffer.payload)
    boxes = state.boxes ++ boxes

    # Make sure that the "rest" is actually the mdat box
    state = %{state | boxes: boxes, partial: rest, last_box_header: parse_header(rest)}

    {actions, state} =
      if can_read_data_box(state) do
        state = %{state | sample_data: SampleHelper.get_sample_data(state.boxes[:moov])}

        # parse the data we received so far (partial or the whole box in a single buffer) and
        # store the samples - they will be sent either in next handle_process or in
        # handle_end_of_stream

        data =
          cond do
            :mdat in state.boxes ->
              state.boxes[:mdat].content

            state.last_box_header.type == :mdat ->
              <<_header::binary-size(@mdat_header_size), content::binary>> = state.partial
              content

            true ->
              <<>>
          end

        {samples, rest, sample_data} = SampleHelper.get_samples(state.sample_data, data)

        state = %{state | sample_data: sample_data, partial: rest}

        all_pads_connected? = all_pads_connected?(ctx, state)

        {buffers, state} =
          if all_pads_connected? do
            {get_buffer_actions(samples), state}
          else
            {[], store_samples(state, samples)}
          end

        demand = [
          demand:
            {:input,
             Enum.map(ctx.pads, fn {_pad, pad_data} ->
               pad_data.demand
             end)
             |> Enum.max(fn -> 0 end)}
        ]

        notifications = get_track_notifications(state.boxes[:moov])
        caps = if all_pads_connected?, do: get_caps(state.boxes[:moov]), else: []

        {notifications ++ caps ++ buffers ++ demand,
         %{state | all_pads_connected?: all_pads_connected?}}
      else
        {[demand: {:input, 1}], state}
      end

    {{:ok, actions}, state}
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
      {:error, _reason} -> nil
    end
  end

  defp can_read_data_box(state) do
    Enum.all?(@header_boxes, &Keyword.has_key?(state.boxes, &1)) and
      ((Map.has_key?(state.last_box_header, :type) and state.last_box_header.type == :mdat) or
         Keyword.has_key?(state.boxes, :mdat))
  end

  defp get_track_notifications(moov) do
    moov.children
    |> Enum.filter(&match?({:trak, _v}, &1))
    |> Enum.map(fn track ->
      boxes = elem(track, 1).children

      sample_table =
        SampleTableBox.unpack(
          boxes[:mdia].children[:minf].children[:stbl],
          boxes[:mdia].children[:mdhd].fields.timescale
        )

      content = sample_table.sample_description.content
      {:notify, {:new_track, boxes[:tkhd].fields.track_id, content}}
    end)
  end

  defp get_caps(moov) do
    moov.children
    |> Enum.filter(&match?({:trak, _v}, &1))
    |> Enum.map(fn track ->
      boxes = elem(track, 1).children
      track_id = boxes[:tkhd].fields.track_id

      sample_table =
        SampleTableBox.unpack(
          boxes[:mdia].children[:minf].children[:stbl],
          boxes[:mdia].children[:mdhd].fields.timescale
        )

      caps = %Membrane.MP4.Payload{
        content: sample_table.sample_description.content,
        timescale: sample_table.timescale,
        height: sample_table.sample_description.height,
        width: sample_table.sample_description.width
      }

      {:caps, {Pad.ref(:output, track_id), caps}}
    end)
  end

  @impl true
  def handle_pad_added(:input, _ctx, state) do
    {:ok, state}
  end

  def handle_pad_added(_pad, _ctx, %{all_pads_connected?: true}) do
    raise "All track have corresponding pad already connected"
  end

  def handle_pad_added(Pad.ref(:output, track_id), ctx, state) do
    # send caps
    all_pads_connected? = all_pads_connected?(ctx, state)

    actions =
      if all_pads_connected? do
        {buffer_actions, state} = flush_samples(state, track_id)
        maybe_caps = if state.sample_data != nil, do: get_caps(state.boxes[:moov]), else: []
        maybe_eos = if state.end_of_stream?, do: [forward: :end_of_stream], else: []

        maybe_caps ++ buffer_actions ++ maybe_eos
      else
        []
      end

    {{:ok, actions}, %{state | all_pads_connected?: all_pads_connected?}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{all_pads_connected?: false} = state) do
    {:ok, %{state | end_of_stream?: true}}
  end

  def handle_end_of_stream(:input, _ctx, %{all_pads_connected?: true} = state) do
    Enum.each(state.buffered_samples, fn {_track_id, samples} ->
      if length(samples) > 0 do
        raise "All samples should be flushed when EOS and pads connected"
      end
    end)

    {{:ok, forward: :end_of_stream}, state}
  end

  defp all_pads_connected?(ctx, state) do
    state.sample_data != nil and
      Enum.all?(1..state.sample_data.tracks_number, fn track_id ->
        Map.has_key?(ctx.pads, Pad.ref(:output, track_id))
      end)
  end

  defp flush_samples(state, track_id) do
    actions =
      Map.get(state.buffered_samples, track_id, [])
      |> Enum.reverse()
      |> Enum.map(fn {buffer, track_id} ->
        {:buffer, {Pad.ref(:output, track_id), buffer}}
      end)

    {actions, put_in(state, [:buffered_samples, track_id], [])}
  end
end
