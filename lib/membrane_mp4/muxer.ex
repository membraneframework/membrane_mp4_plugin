defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.MP4.Container
  alias __MODULE__.{MovieBox, Track}

  @ftyp [
    ftyp: %{
      children: [],
      fields: %{
        compatible_brands: ["isom", "iso2", "avc1", "mp41"],
        major_brand: "isom",
        major_brand_version: 512
      }
    }
  ] |> Container.serialize!()

  @mdat_data_offset 8
  @first_chunk_offset byte_size(@ftyp) + @mdat_data_offset

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
      chunk_offset: @first_chunk_offset,
      media_data: <<>>
    }

    {:ok, state}
  end

  @impl true
  def handle_caps({_pad, :input, pad_ref}, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    track =
      caps
      |> Map.take([:width, :height, :content, :timescale])
      |> Map.put(:id, state.next_id)
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
    state = update_in(state, [:playing, pad_ref], &Track.store_sample(&1, buffer))

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream({_pad, :input, pad_ref}, _ctx, state) do
    {track, state} = pop_in(state, [:playing, pad_ref])
    {chunk, track} = Track.flush_chunk(track, state.chunk_offset)

    state =
      state
      |> Map.update!(:chunk_offset, &(&1 + byte_size(chunk)))
      |> Map.update!(:media_data, &(&1 <> chunk))
      |> Map.update!(:stopped, &[track | &1])

    if length(state.stopped) < state.tracks do
      {:ok, state}
    else
      mdat = [mdat: %{content: state.media_data}] |> Container.serialize!()
      moov = MovieBox.serialize(state.stopped)
      mp4 = @ftyp <> mdat <> moov

      {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
    end
  end
end
