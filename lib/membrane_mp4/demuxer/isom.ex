defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc false
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
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        boxes: [],
        last_box_header: nil,
        partial: <<>>,
        sample_data: nil,
        all_pads_connected?: false,
        buffered_samples: %{},
        end_of_stream?: false
      })

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_caps(Pad.ref(:input, _track_id) = _pad, _caps, _ctx, state) do
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

  def handle_process(:input, buffer, _ctx, %{sample_data: nil} = state) do
    # parse the boxes we have received
    {boxes, rest} = Container.parse!(state.partial <> buffer)
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

        all_pads_connected? = map_size(state.pads) == state.sample_data.tracks_number

        {actions, state} =
          if all_pads_connected? and :mdat in state.boxes do
            {get_buffer_actions(samples), state}
          else
            {[], %{store_samples(state, samples) | sample_data: sample_data, partial: rest}}
          end

        notifications = get_track_notifications(state.boxes[:moov])
        caps = if all_pads_connected?, do: get_caps(state.boxes[:moov]), else: []

        {notifications ++ caps ++ actions, %{state | all_pads_connected?: all_pads_connected?}}
      else
        {[demand: :input], state}
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
      {:buffer, {Pad.ref(:input, track_id), buffer}}
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
      sample_table = SampleTableBox.unpack(track.children[:mdia].children[:minf].children[:stbl])

      content = sample_table.sample_description.content
      {:new_track, track.children[:tkhd].fields.track_id, content}
    end)
  end

  defp get_caps(moov) do
    moov.children
    |> Enum.filter(&match?({:trak, _v}, &1))
    |> Enum.map(fn track ->
      track_id = track.children[:tkhd].fields.track_id
      boxes = track.children

      sample_table = SampleTableBox.unpack(boxes[:mdia].children[:minf].children[:stbl])

      caps = %Membrane.MP4.Payload{
        content: sample_table.sample_description.content,
        timescale: boxes[:mdia].children[:mdhd].fields.timescale,
        height: boxes[:thhd].fields.height |> elem(0),
        width: boxes[:thhd].fields.width |> elem(0)
      }

      {:caps, {Pad.ref(:output, track_id), caps}}
    end)
  end

  @impl true
  def handle_pad_added(_pad, _ctx, %{all_pads_connected?: true}) do
    raise "All track have corresponding pad already connected"
  end

  def handle_pad_added(Pad.ref(:input, track_id), _ctx, state) do
    # send caps
    all_pads_connected? =
      state.sample_data != nil and
        Enum.all?(
          1..state.sample_data.tracks_number,
          &Map.has_key?(state.pads, Pad.ref(:output, &1))
        )

    actions =
      if all_pads_connected? do
        {buffer_actions, state} = flush_samples(state, track_id)
        maybe_caps = if state.sample_data != nil, do: get_caps(state.boxes[:moov]), else: []

        maybe_eos =
          if state.end_of_stream? do
            Enum.map(1..state.sample_data.track_number, fn track_id ->
              {:end_of_stream, Pad.ref(:output, track_id)}
            end)
          else
            []
          end

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
    Enum.each(state.buffered_samples, fn map ->
      if map_size(map) > 0 do
        raise "All samples should be flush when EOS and pads connected"
      end
    end)

    actions =
      Enum.map(1..state.sample_data.track_number, fn track_id ->
        {:end_of_stream, Pad.ref(:output, track_id)}
      end)

    {{:ok, actions}, state}
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
