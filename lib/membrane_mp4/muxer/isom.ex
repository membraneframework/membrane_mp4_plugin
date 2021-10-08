defmodule Membrane.MP4.Muxer.ISOM do
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
  # correcting the mdat header after all media data has been sent.

  use Membrane.Filter

  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.{MovieBox, Track}

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

  @ftyp_size @ftyp |> Container.serialize!() |> byte_size()
  @mdat_data_offset 8

  def_input_pad :input,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  def_output_pad :output, caps: :buffers

  def_options fast_start: [
                spec: boolean,
                default: false,
                description: """
                Whether the container metadata (`moov` atom) should be placed before media data.

                Especially suitable for streaming, where makes it possible to start playback before all
                media data arrives. Equivalent of `ffmpeg`'s `-movflags faststart` option.
                """
              ],
              chunk_duration: [
                spec: Time.t(),
                default: Time.seconds(1),
                description: """
                Expected duration of each chunk in the resulting MP4 container.

                Once the total duration of samples received on one of the input pads exceeds
                that threshold, a chunk containing these samples is flushed. Interleaving chunks
                belonging to different tracks may have positive impact on performance of media players.
                """
              ]

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        pad_to_track: %{},
        pad_order: [],
        media_data: <<>>
      })

    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, pad_ref), _ctx, state) do
    state = Map.update!(state, :pad_order, &[pad_ref | &1])

    {:ok, state}
  end

  @impl true
  def handle_caps(Pad.ref(:input, pad_ref), %Membrane.MP4.Payload{} = caps, _ctx, state) do
    track =
      caps
      |> Map.take([:width, :height, :content, :timescale])
      |> Track.new()

    state = put_in(state, [:pad_to_track, pad_ref], track)

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    next_ref = hd(state.pad_order)

    {{:ok, demand: {Pad.ref(:input, next_ref), 1}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, pad_ref), buffer, _ctx, state) do
    state =
      state
      |> update_in([:pad_to_track, pad_ref], &Track.store_sample(&1, buffer))
      |> maybe_flush_chunk(pad_ref)

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, pad_ref), _ctx, state) do
    state =
      state
      |> do_flush_chunk(pad_ref)
      |> Map.update!(:pad_order, &List.delete(&1, pad_ref))

    if length(state.pad_order) > 0 do
      {{:ok, redemand: :output}, state}
    else
      mp4 = serialize(state)

      {{:ok, buffer: {:output, %Buffer{payload: mp4}}, end_of_stream: :output}, state}
    end
  end

  defp maybe_flush_chunk(state, pad_ref) do
    use Ratio, comparison: true
    track = get_in(state, [:pad_to_track, pad_ref])

    if Track.current_chunk_duration(track) >= state.chunk_duration do
      do_flush_chunk(state, pad_ref)
    else
      state
    end
  end

  defp do_flush_chunk(state, pad_ref) do
    track = get_in(state, [:pad_to_track, pad_ref])

    {chunk, track} = Track.flush_chunk(track, chunk_offset(state))

    state
    |> Map.update!(:media_data, &(&1 <> chunk))
    |> put_in([:pad_to_track, pad_ref], track)
    |> Map.update!(:pad_order, &shift_left/1)
  end

  defp serialize(state) do
    mdat = [mdat: %{content: state.media_data}]
    moov = state.pad_to_track |> Map.values() |> MovieBox.assemble()

    if state.fast_start do
      [@ftyp, fast_start_moov(moov), mdat]
    else
      [@ftyp, mdat, moov]
    end
    |> Enum.map(&Container.serialize!/1)
    |> Enum.reduce(&(&2 <> &1))
  end

  defp fast_start_moov(moov) do
    moov_size = moov |> Container.serialize!() |> byte_size()
    moov_children = get_in(moov, [:moov, :children])

    # updates all `trak` boxes by adding `moov_size` to the offset of each chunk in its sample table
    traks_with_offset =
      moov_children
      |> Keyword.get_values(:trak)
      |> Enum.map(fn trak ->
        Container.update_box(
          trak.children,
          [:mdia, :minf, :stbl, :stco],
          [:fields, :entry_list],
          &Enum.map(&1, fn %{chunk_offset: offset} -> %{chunk_offset: offset + moov_size} end)
        )
      end)
      |> Enum.reduce([], &([trak: %{children: &1, fields: %{}}] ++ &2))

    # replaces all `trak` boxes with the ones with updated chunk offsets
    moov_children
    |> Keyword.delete(:trak)
    |> Keyword.merge(traks_with_offset)
    |> then(&[moov: %{children: &1, fields: %{}}])
  end

  defp chunk_offset(%{media_data: media_data}),
    do: @ftyp_size + @mdat_data_offset + byte_size(media_data)

  defp shift_left([]), do: []

  defp shift_left([first | rest]), do: rest ++ [first]
end
