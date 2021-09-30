defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """

  # Due to the structure of MPEG-4 containers, it is not possible
  # to send buffers with `mdat` box content right after they are
  # processed — we need to know the size of this box up front.
  # The current solution requires storing all incoming buffers
  # in memory until the last track ends.
  # Once some kind of seeking mechanism is implemented, it will
  # be possible to send chunks of samples on demand, only
  # correcting the mdat header after all media data was send.

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
        ]
        |> Container.serialize!()

  @mdat_data_offset 8

  @default_samples_per_chunk 10

  def_input_pad :input,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  def_output_pad :output, caps: :buffers

  def_options tracks: [
                spec: pos_integer,
                default: 1,
                description: "Number of tracks that the muxer should expect"
              ],
              samples_per_chunk: [
                spec: :auto | pos_integer,
                default: :auto,
                description: """
                Number of samples per chunk (the last chunk may be smaller).

                If set to `:auto`, it's determined by the number of tracks —
                for two or more it equals `@default_samples_per_chunk`,
                otherwise no upper limit is set.
                """
              ]

  @impl true
  def handle_init(options) do
    state = %{
      playing: %{},
      stopped: [],
      media_data: <<>>,
      chunk_offset: byte_size(@ftyp) + @mdat_data_offset,
      tracks: options.tracks,
      samples_per_chunk:
        case {options.samples_per_chunk, options.tracks} do
          {:auto, 1} -> :infinity
          {:auto, _} -> @default_samples_per_chunk
          _ -> options.samples_per_chunk
        end
    }

    {:ok, state}
  end

  @impl true
  def handle_caps({_pad, :input, pad_ref}, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    track =
      caps
      |> Map.take([:width, :height, :content, :timescale])
      |> Track.new()

    state = put_in(state, [:playing, pad_ref], track)

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
    state =
      state
      |> update_in([:playing, pad_ref], &Track.store_sample(&1, buffer))
      |> maybe_flush_chunk(pad_ref)

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
      mdat = [mdat: %{content: state.media_data}] |> Container.serialize!()
      moov = MovieBox.serialize(state.stopped)
      mp4 = @ftyp <> mdat <> moov

      {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
    end
  end

  defp maybe_flush_chunk(%{samples_per_chunk: :infinity} = state, _pad_ref), do: state

  defp maybe_flush_chunk(state, pad_ref) do
    track = get_in(state, [:playing, pad_ref])

    if Track.current_buffer_size(track) == state.samples_per_chunk do
      {chunk, track} = Track.flush_chunk(track, state.chunk_offset)

      state
      |> Map.update!(:chunk_offset, &(&1 + byte_size(chunk)))
      |> Map.update!(:media_data, &(&1 <> chunk))
      |> put_in([:playing, pad_ref], track)
    else
      state
    end
  end
end
