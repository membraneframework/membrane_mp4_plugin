defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.MP4.{CommonBox, Container, Track}

  def_input_pad :input,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  def_output_pad :output, caps: :buffers

  def_options timescale: [
                type: :integer,
                default: 1000,
                description: "Common timescale for all tracks in the container"
              ],
              tracks: [
                type: :integer,
                default: 1,
                descriptions: "Number of tracks that the muxer should expect"
              ]

  @impl true
  def handle_init(options) do
    state = %{
      timescale: options.timescale,
      playing: %{},
      stopped: %{},
      awaiting: options.tracks
    }

    {:ok, state}
  end

  @impl true
  def handle_caps({_pad, :input, ref}, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    track =
      caps
      |> Map.take([:timescale, :width, :height, :content])
      |> Map.put(:id, state.awaiting)
      |> Track.new()

    state =
      state
      |> put_in([:playing, ref], track)
      |> Map.update!(:awaiting, &(&1 - 1))

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    demands =
      state.playing
      |> Map.keys()
      |> Enum.map(&{:demand, {Pad.ref(:input, &1), size}})

    {{:ok, demands}, state}
  end

  @impl true
  def handle_process_list({_pad, :input, ref}, buffers, _ctx, state) do
    state = update_in(state, [:playing, ref], &Track.store_buffers(&1, buffers))

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream({_pad, :input, ref}, _ctx, state) do
    {track, state} = pop_in(state, [:playing, ref])

    state = put_in(state, [:stopped, ref], Track.finalize(track, state.timescale))

    case {state.awaiting, state.playing} do
      {0, %{}} ->
        tracks = state.stopped |> Map.values()

        ftyp = CommonBox.file_type_box()

        payloads = Enum.map(tracks, &Track.payload/1)
        offsets = [0 | payloads |> Enum.map(&byte_size/1) |> tl()]
        mdat = payloads |> Enum.join() |> CommonBox.media_data_box()

        moov = CommonBox.movie_box(tracks, state.timescale, offsets)

        mp4 = (ftyp ++ mdat ++ moov) |> Container.serialize!()

        {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
      _ ->
        {:ok, state}
    end
  end
end
