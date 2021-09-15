defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.MP4.Container
  alias __MODULE__.{Box, Track}

  @timescale 1000
  # once pull mode is available, make chunks only when it's needed
  @samples_per_chunk 100

  def_input_pad :input,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  def_output_pad :output, caps: :buffers

  def_options tracks: [
                type: :integer,
                default: 1,
                description: "Number of tracks that the muxer should expect"
              ]

  @impl true
  def handle_init(options) do
    state = %{
      tracks: options.tracks,
      next_id: 1,
      playing: %{},
      stopped: [],
      chunk_offset: 0,
      media_data: <<>>
    }

    {:ok, state}
  end

  @impl true
  def handle_caps({_pad, :input, pad_ref}, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    track =
      caps
      |> Map.take([:width, :height, :timescale])
      |> Map.merge(%{
        id: state.next_id,
        codec: caps.content
      })
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
  def handle_process({_pad, :input, pad_ref}, buffer, _ctx, state) do
    track =
      get_in(state, [:playing, pad_ref])
      |> Track.store_sample(buffer)

    # once pull mode is available, flush only on demand
    state =
      if track.buffer.current_size == @samples_per_chunk do
        {chunk, track} = Track.flush_chunk(track, state.chunk_offset)

        state
        |> Map.update!(:chunk_offset, &(&1 + byte_size(chunk)))
        |> Map.update!(:media_data, &(&1 <> chunk))
        |> put_in([:playing, pad_ref], track)
      else
        state
        |> put_in([:playing, pad_ref], track)
      end

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream({_pad, :input, pad_ref}, _ctx, state) do
    {track, state} = pop_in(state, [:playing, pad_ref])
    {last_chunk, track} = Track.flush_chunk(track, state.chunk_offset)

    state =
      state
      |> Map.update!(:chunk_offset, &(&1 + byte_size(last_chunk)))
      |> Map.update!(:media_data, &(&1 <> last_chunk))
      |> Map.update!(:stopped, &[track | &1])

    if length(state.stopped) < state.tracks do
      {:ok, state}
    else
      ftyp = Box.file_type_box()
      mdat = Box.media_data_box(state.media_data)
      moov = Box.movie_box(state.stopped, @timescale)

      mp4 = (ftyp ++ mdat ++ moov) |> Container.serialize!()

      {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
    end
  end
end
