defmodule Membrane.MP4.Muxer.ISOM do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, File, MP4, RemoteStream, Time, TimestampQueue}
  alias Membrane.MP4.{Container, FileTypeBox, MediaDataBox, MovieBox, Track}

  @ftyp FileTypeBox.assemble("isom", ["isom", "iso2", "avc1", "mp41"])
  @ftyp_size @ftyp |> Container.serialize!() |> byte_size()
  @mdat_header_size 8

  def_input_pad :input,
    flow_control: :auto,
    accepted_format:
      any_of(
        %Membrane.AAC{config: {:esds, _esds}},
        %Membrane.H264{
          stream_structure: {:avc1, _dcr},
          alignment: :au
        },
        %Membrane.H265{
          stream_structure: {_hevc, _dcr},
          alignment: :au
        },
        %Membrane.Opus{self_delimiting?: false}
      ),
    availability: :on_request

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :bytestream, content_format: MP4},
    flow_control: :auto

  def_options fast_start: [
                spec: boolean(),
                default: false,
                description: """
                Generates a container more suitable for streaming by allowing media players to start
                playback as soon as they start to receive its media data.

                When set to `true`, the container metadata (`moov` atom) will be placed before media
                data (`mdat` atom). The equivalent of FFmpeg's `-movflags faststart` option.
                [IMPORTANT] Due to the structure of MPEG-4 containers, the muxer with `fast_start: true`
                has to be used along with `Membrane.File.Sink` or any other sink that can handle `Membrane.File.SeekSinkEvent`,
                since that event is used to insert `moov` box at the beginning of the file.
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
  def handle_init(_ctx, options) do
    queue =
      TimestampQueue.new(
        chunk_duration: options.chunk_duration,
        pause_demand_boundary: 3 * options.chunk_duration,
        pause_demand_boundary_unit: :time
      )

    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        mdat_size: 0,
        next_track_id: 1,
        pad_order: [],
        pad_to_track: %{},
        queue: queue
      })

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, pad_ref) = pad, _ctx, state) do
    {track_id, state} = Map.get_and_update!(state, :next_track_id, &{&1, &1 + 1})

    state =
      state
      |> Map.update!(:pad_order, &[pad_ref | &1])
      |> put_in([:pad_to_track, pad_ref], track_id)
      |> Map.update!(:queue, &TimestampQueue.register_pad(&1, pad))

    {[], state}
  end

  @impl true
  def handle_stream_format(
        Pad.ref(:input, pad_ref) = pad,
        stream_format,
        ctx,
        state
      ) do
    cond do
      # Handle receiving the first stream format on the given pad
      is_nil(ctx.pads[pad].stream_format) ->
        update_in(state, [:pad_to_track, pad_ref], fn track_id ->
          Track.new(track_id, stream_format, state.chunk_duration)
        end)

      # Handle receiving all but the first stream format on the given pad,
      # when stream format is duplicated - ignore
      ctx.pads[pad].stream_format == stream_format ->
        state

      # otherwise we can assume that output will be corrupted
      true ->
        raise "ISOM Muxer doesn't support variable parameters"
    end
    |> then(&{[], &1})
  end

  @impl true
  def handle_playing(_ctx, state) do
    # dummy mdat header will be overwritten in `finalize_mp4/1`, when media data size is known
    header = [@ftyp, MediaDataBox.assemble(<<>>)] |> Enum.map_join(&Container.serialize!/1)

    actions = [
      stream_format: {:output, %RemoteStream{content_format: MP4}},
      buffer: {:output, %Buffer{payload: header}}
    ]

    {actions, state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, _pad_ref) = pad, buffer, _ctx, state) do
    state.queue
    |> TimestampQueue.push_buffer_and_pop_available_items(pad, buffer)
    |> handle_queue_output(state)
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _pad_ref) = pad, _ctx, state) do
    state.queue
    |> TimestampQueue.push_end_of_stream(pad)
    |> TimestampQueue.pop_available_items()
    |> handle_queue_output(state)
  end

  defp handle_queue_output({suggested_actions, batch, queue}, state) do
    {actions, state} = Enum.flat_map_reduce(batch, state, &handle_queue_item/2)
    {suggested_actions ++ actions, %{state | queue: queue}}
  end

  defp handle_queue_item({Pad.ref(:input, pad_ref), {:buffer, buffer}}, state) do
    # In case DTS is not set, use PTS. This is the case for audio tracks or H264 originated
    # from an RTP stream. ISO base media file format specification uses DTS for calculating
    # decoding deltas, and so is the implementation of sample table in this plugin.
    buffer = %Buffer{buffer | dts: Buffer.get_dts_or_pts(buffer)}

    state
    |> update_in([:pad_to_track, pad_ref], &Track.store_sample(&1, buffer))
    |> maybe_flush_chunk(pad_ref)
  end

  defp handle_queue_item({Pad.ref(:input, pad_ref), :end_of_stream}, state) do
    {buffer, state} = do_flush_chunk(state, pad_ref)
    state = Map.update!(state, :pad_order, &List.delete(&1, pad_ref))

    if state.pad_order != [] do
      {buffer, state}
    else
      actions = finalize_mp4(state)
      {buffer ++ actions ++ [end_of_stream: :output], state}
    end
  end

  defp maybe_flush_chunk(state, pad_ref) do
    track = get_in(state, [:pad_to_track, pad_ref])

    if Track.completed?(track) do
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
      event: {:output, %File.SeekSinkEvent{position: after_ftyp}},
      buffer: {:output, %Buffer{payload: <<mdat_total_size::32>>}}
    ]

    if state.fast_start do
      moov = movie_box |> prepare_for_fast_start() |> Container.serialize!()

      update_mdat_actions ++
        [
          event: {:output, %File.SeekSinkEvent{position: after_ftyp, insert?: true}},
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
