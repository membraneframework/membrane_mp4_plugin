defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}

  def_input_pad :input,
    caps: {RemoteStream, type: :bytestream, content_format: one_of([nil, MP4])},
    demand_unit: :buffers

  def_output_pad :output,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  @type new_track_t() ::
          {:new_track, integer(), %{type: :audio | :video, codec: :aac | :opus | :h264}}

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        boxes: [],
        buffer: <<>>,
        mdat_bytes_read: 0,
        track_info_read?: false,
        tracks: %{}
      })

    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, ctx, %{track_info_read?: true} = state) do
    # check if all tracks have corresponding output pads

    # maybe send buffer (sample(s)), if enough data
    {actions, state} = {[], state}
    {{:ok, actions}, state}
  end

  def handle_process(:input, buffer, ctx, state) do
    # check if all tracks have corresponding output pads
    {actions, state} =
      if Enum.all?([:ftyp, :moov], &Keyword.has_key?(state.boxes, &1)) do
        actions = get_track_notifications(state.boxes[:moov])

        # notify about number and types of tracks
        {actions, %{state | track_info_ready?: true}}
      else
        {[], state}
      end

    {{:ok, actions}, state}
  end

  defp get_track_notifications(moov) do
    moov.children
    |> Enum.filter(fn {k, _v} -> k == :trak end)
    |> Enum.map(fn track ->
      {:new_track, track.children[:tkhd].fields.track_id,
       track.children[:mdia].children[:hdlr].fields.handler_type |> parse_handler_type()}
    end)
  end

  defp parse_handler_type(handler_type) do
    case handler_type do
      "soun" -> :audio
      "vide" -> :video
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id), _ctx, state) do
    # send caps
    {:ok, state}
  end

  @impl true
  def handle_caps(Pad.ref(:input, pad_ref) = pad, %Membrane.MP4.Payload{} = caps, ctx, state) do
    cond do
      # Handle receiving very first caps on the given pad
      is_nil(ctx.pads[pad].caps) ->
        update_in(state, [:pad_to_track, pad_ref], fn track_id ->
          caps
          |> Map.take([:width, :height, :content, :timescale])
          |> Map.put(:id, track_id)
          |> Track.new()
        end)

      # Handle receiving all but first caps on the given pad when
      # inband_parameters? are allowed or caps are duplicated - ignore
      Map.get(ctx.pads[pad].caps.content, :inband_parameters?, false) ||
          ctx.pads[pad].caps == caps ->
        state

      # otherwise we can assume that output will be corrupted
      true ->
        raise("ISOM Muxer doesn't support variable parameters")
    end
    |> then(&{:ok, &1})
  end
end
