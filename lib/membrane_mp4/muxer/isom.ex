defmodule Membrane.MP4.Muxer.ISOM do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.

  Due to the structure of MPEG-4 containers, the muxer has to be used along with
  `Membrane.File.Sink` or any other sink that can handle `Membrane.File.SeekEvent`.
  The event is used to fill in `mdat` box size after processing all incoming buffers
  and, if `fast_start` is set to `true`, to insert `moov` box at the beginning of the file.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, File, Time}
  alias Membrane.MP4.{Container, FileTypeBox, MediaDataBox, MovieBox, Track}

  @ftyp FileTypeBox.assemble("isom", ["isom", "iso2", "avc1", "mp41"])
  @ftyp_size @ftyp |> Container.serialize!() |> byte_size()
  @mdat_header_size 8

  def_input_pad :input,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  def_output_pad :output, caps: :buffers

  def_options fast_start: [
                spec: boolean(),
                default: false,
                description: """
                Generates a container more suitable for streaming by allowing media players to start
                playback as soon as they start to receive its media data.

                When set to `true`, the container metadata (`moov` atom) will be placed before media
                data (`mdat` atom). The equivalent of FFmpeg's `-movflags faststart` option.
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
        mdat_size: 0,
        next_track_id: 1,
        pad_order: [],
        pad_to_track: %{}
      })

    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, pad_ref), _ctx, state) do
    {track_id, state} = Map.get_and_update!(state, :next_track_id, &{&1, &1 + 1})

    state =
      state
      |> Map.update!(:pad_order, &[pad_ref | &1])
      |> put_in([:pad_to_track, pad_ref], track_id)

    {:ok, state}
  end

  @impl true
  def handle_caps(Pad.ref(:input, pad_ref) = pad, %Membrane.MP4.Payload{} = caps, ctx, state) do
    cond do
      is_nil(ctx.pads[pad].caps) ->
        update_in(state, [:pad_to_track, pad_ref], fn track_id ->
          caps
          |> Map.take([:width, :height, :content, :timescale])
          |> Map.put(:id, track_id)
          |> Track.new()
        end)

      ctx.pads[pad].caps.content.inband_parameters? || ctx.pads[pad].caps == caps ->
        state

      true ->
        raise("ISOM Muxer doesn't support variable parameters")
    end
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    # dummy mdat header will be overwritten in `finalize_mp4/1`, when media data size is known
    header = [@ftyp, MediaDataBox.assemble(<<>>)] |> Enum.map_join(&Container.serialize!/1)

    {{:ok, buffer: {:output, %Buffer{payload: header}}}, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    next_ref = hd(state.pad_order)

    {{:ok, demand: {Pad.ref(:input, next_ref), 1}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, pad_ref), buffer, _ctx, state) do
    {maybe_buffer, state} =
      state
      |> update_in([:pad_to_track, pad_ref], &Track.store_sample(&1, buffer))
      |> maybe_flush_chunk(pad_ref)

    {{:ok, maybe_buffer ++ [redemand: :output]}, state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, pad_ref), _ctx, state) do
    {buffer, state} = do_flush_chunk(state, pad_ref)
    state = Map.update!(state, :pad_order, &List.delete(&1, pad_ref))

    if state.pad_order != [] do
      {{:ok, buffer ++ [redemand: :output]}, state}
    else
      actions = finalize_mp4(state)
      {{:ok, buffer ++ actions ++ [end_of_stream: :output]}, state}
    end
  end

  defp maybe_flush_chunk(state, pad_ref) do
    use Ratio, comparison: true
    track = get_in(state, [:pad_to_track, pad_ref])

    if Track.current_chunk_duration(track) >= state.chunk_duration do
      do_flush_chunk(state, pad_ref)
    else
      {[], state}
    end
  end

  defp do_flush_chunk(state, pad_ref) do
    {chunk, track} =
      state
      |> get_in([:pad_to_track, pad_ref])
      |> Track.flush_chunk(chunk_offset(state))

    state =
      state
      |> Map.put(:mdat_size, state.mdat_size + byte_size(chunk))
      |> put_in([:pad_to_track, pad_ref], track)
      |> Map.update!(:pad_order, &shift_left/1)

    {[buffer: {:output, %Buffer{payload: chunk}}], state}
  end

  defp finalize_mp4(state) do
    movie_box = state.pad_to_track |> Map.values() |> Enum.sort_by(& &1.id) |> MovieBox.assemble()
    after_ftyp = {:bof, @ftyp_size}
    mdat_total_size = @mdat_header_size + state.mdat_size

    update_mdat_actions = [
      event: {:output, %File.SeekEvent{position: after_ftyp}},
      buffer: {:output, %Buffer{payload: <<mdat_total_size::32>>}}
    ]

    if state.fast_start do
      moov = movie_box |> prepare_for_fast_start() |> Container.serialize!()

      update_mdat_actions ++
        [
          event: {:output, %File.SeekEvent{position: after_ftyp, insert?: true}},
          buffer: {:output, %Buffer{payload: moov}}
        ]
    else
      moov = Container.serialize!(movie_box)

      [buffer: {:output, %Buffer{payload: moov}}] ++ update_mdat_actions
    end
  end

  defp prepare_for_fast_start(movie_box) do
    movie_box_size = movie_box |> Container.serialize!() |> byte_size()
    movie_box_children = get_in(movie_box, [:moov, :children])

    # updates all `trak` boxes by adding `movie_box_size` to the offset of each chunk in their sample tables
    track_boxes_with_offset =
      movie_box_children
      |> Keyword.get_values(:trak)
      |> Enum.map(fn trak ->
        Container.update_box(
          trak.children,
          [:mdia, :minf, :stbl, :stco],
          [:fields, :entry_list],
          &Enum.map(&1, fn %{chunk_offset: offset} -> %{chunk_offset: offset + movie_box_size} end)
        )
      end)
      |> Enum.map(&{:trak, %{children: &1, fields: %{}}})

    # replaces all `trak` boxes with the ones with updated chunk offsets
    movie_box_children
    |> Keyword.delete(:trak)
    |> Keyword.merge(track_boxes_with_offset)
    |> then(&[moov: %{children: &1, fields: %{}}])
  end

  defp chunk_offset(%{mdat_size: mdat_size}),
    do: @ftyp_size + @mdat_header_size + mdat_size

  defp shift_left([]), do: []

  defp shift_left([first | rest]), do: rest ++ [first]
end
