defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.MP4.Container
  alias Membrane.MP4.Common.{Box, Track}

  def_input_pad :input,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  def_output_pad :output, caps: :buffers

  def_options tracks: [
                type: :integer,
                default: 1,
                descriptions: "Number of tracks that the muxer should expect"
              ],
              timescale: [
                type: :integer,
                default: 1000,
                description: "Common timescale for all tracks in the container"
              ]

  @impl true
  def handle_init(options) do
    state = %{
      n_tracks: options.tracks,
      timescale: options.timescale,
      next_id: 1,
      playing: %{},
      stopped: []
    }

    {:ok, state}
  end

  @impl true
  def handle_caps({_pad, :input, pad_ref}, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    track =
      caps
      |> Map.take([:timescale, :width, :height, :content])
      |> Map.merge(%{id: state.next_id, kind: :mp4})
      |> Track.new()

    state =
      state
      |> put_in([:playing, pad_ref], track)
      |> Map.update!(:next_id, &(&1 + 1))

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
  def handle_process_list({_pad, :input, pad_ref}, buffers, _ctx, state) do
    state = update_in(state, [:playing, pad_ref], &Track.store_buffers(&1, buffers))

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream({_pad, :input, pad_ref}, _ctx, state) do
    {track, state} = pop_in(state, [:playing, pad_ref])

    state = Map.update!(state, :stopped, &[Track.update_duration(track, state.timescale) | &1])

    if length(state.stopped) < state.n_tracks do
      {:ok, state}
    else
      ftyp = Box.file_type_box()

      mdat =
        state.stopped |> Enum.map(&Track.get_payload/1) |> Enum.join() |> Box.media_data_box()

      moov = Box.movie_box(state.stopped, state.timescale)

      mp4 = (ftyp ++ mdat ++ moov) |> Container.serialize!() |> IO.inspect(label: :eos)

      {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
    end
  end
end
