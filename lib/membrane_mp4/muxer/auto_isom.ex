defmodule Membrane.MP4.Muxer.AutoISOM do
  @moduledoc """
  Ala ma kota.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, File, MP4, RemoteStream, Time}
  alias Membrane.MP4.{Container, FileTypeBox, MediaDataBox, MovieBox, Track}

  @ftyp FileTypeBox.assemble("isom", ["isom", "iso2", "avc1", "mp41"])
  @ftyp_size @ftyp |> Container.serialize!() |> byte_size()
  @mdat_header_size 8
  @track_awaiting_buffers_upperbound 1000

  def_input_pad :input,
    accepted_format:
      any_of(
        %Membrane.AAC{config: {:esds, _esds}},
        %Membrane.H264{
          stream_structure: {:avc1, _dcr},
          alignment: :au
        },
        %Membrane.Opus{self_delimiting?: false}
      ),
    availability: :on_request,
    flow_control: :auto

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
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        mdat_size: 0,
        pad_to_track: %{},
        next_track_id: 1
      })

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, pad_id), _ctx, state) do
    state
    |> put_in([:pad_to_track, pad_id], %{
      track_data: nil,
      awaiting_buffers: [],
      chunk_dts_bound: nil,
      chunk_completed?: false
    })
    |> then(&{[], &1})
  end

  @impl true
  def handle_stream_format(Pad.ref(:input, pad_id), stream_format, ctx, state) do
    case ctx.old_stream_format do
      nil ->
        # Handle receiving the first stream format on the given pad
        {track_id, state} = Map.get_and_update!(state, :next_track_id, &{&1, &1 + 1})
        put_in(state, [:pad_to_track, pad_id, :track_data], Track.new(track_id, stream_format))

      ^stream_format ->
        state

      _ohter ->
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
  def handle_buffer(Pad.ref(:input, pad_id) = pad_ref, buffer, ctx, state) do
    buffer = %Buffer{buffer | dts: Buffer.get_dts_or_pts(buffer)}

    {flush_tracks_actions, state} =
      store_buffer(pad_id, buffer, state)
      |> maybe_flush_tracks(ctx)

    actions = maybe_pause_demand(pad_ref, state, ctx) ++ flush_tracks_actions

    {actions, state}
  end

  defp maybe_pause_demand(Pad.ref(:input, pad_id) = pad_ref, state, ctx) do
    track = get_in(state, [:pad_to_track, pad_id])

    if track.chunk_completed? and not ctx.pads[pad_ref].auto_demand_paused? and
         length(track.awaiting_buffers) >= @track_awaiting_buffers_upperbound do
      [pause_auto_demand: pad_ref]
    else
      []
    end
  end

  defp store_buffer(pad_id, buffer, state) do
    update_in(
      state,
      [:pad_to_track, pad_id],
      fn track ->
        use Ratio, comparison: true

        cond do
          # first buffer on pad
          track.chunk_dts_bound == nil ->
            %{
              track
              | chunk_dts_bound: buffer.dts + state.chunk_duration,
                track_data: Track.store_sample(track.track_data, buffer)
            }

          # buffer dts is not greater than chunk dts bound
          buffer.dts <= track.chunk_dts_bound ->
            %{track | track_data: Track.store_sample(track.track_data, buffer)}

          # buffer dts is greater than chunch dts bound
          true ->
            %{track | awaiting_buffers: [buffer | track.awaiting_buffers], chunk_completed?: true}
        end
      end
    )
  end

  defp maybe_flush_tracks(state, ctx) do
    if all_chunks_completed?(state) do
      do_flush_tracks(state, ctx)
    else
      {[], state}
    end
  end

  defp all_chunks_completed?(state) do
    state.pad_to_track
    |> Enum.all?(fn {_pad_id, track} -> track.chunk_completed? end)
  end

  defp do_flush_tracks(state, ctx) do
    {buffer_actions, state} =
      Enum.map_reduce(state.pad_to_track, state, fn {pad_id, _track}, state ->
        {chunk, track_data} =
          state
          |> get_in([:pad_to_track, pad_id, :track_data])
          |> Track.flush_chunk(chunk_offset(state))

        action = {:buffer, {:output, %Buffer{payload: chunk}}}

        state =
          state
          |> Map.update!(:mdat_size, &(&1 + byte_size(chunk)))
          |> put_in([:pad_to_track, pad_id, :track_data], track_data)
          |> update_in([:pad_to_track, pad_id], fn track ->
            use Ratio, comparison: true

            chunk_dts_bound = track.chunk_dts_bound + state.chunk_duration

            [buffers_to_store, awaiting_buffers] =
              track.awaiting_buffers
              |> Enum.reverse()
              |> Enum.split_while(&(&1.dts <= chunk_dts_bound))
              |> Tuple.to_list()
              |> Enum.map(&Enum.reverse/1)

            track_data =
              buffers_to_store
              |> Enum.reduce(track.track_data, fn buffer, track_data ->
                Track.store_sample(track_data, buffer)
              end)

            %{
              chunk_dts_bound: chunk_dts_bound,
              awaiting_buffers: awaiting_buffers,
              track_data: track_data,
              chunk_completed?: awaiting_buffers != []
            }
          end)

        {action, state}
      end)

    resume_demand_actions =
      ctx.pads
      |> Enum.filter(fn {pad_ref, pad_data} ->
        pad_data.auto_demand_paused? and awaitng_buffers_in_upperbound?(pad_ref, state)
      end)
      |> Enum.map(fn {pad_ref, _data} -> {:resume_auto_demand, pad_ref} end)

    {buffer_actions ++ resume_demand_actions, state}
  end

  defp awaitng_buffers_in_upperbound?(pad_ref, state) do
    length(state.pad_to_track[pad_ref].awaiting_buffers) < @track_awaiting_buffers_upperbound
  end

  defp chunk_offset(%{mdat_size: mdat_size}),
    do: @ftyp_size + @mdat_header_size + mdat_size

  @impl true
  def handle_end_of_stream(Pad.ref(:input, pad_id), ctx, state) do
    track = get_in(state, [:pad_to_track, pad_id])

    {chunk, track_data} =
      track.awaiting_buffers
      |> List.foldr(track.track_data, fn buffer, track_data ->
        Track.store_sample(track_data, buffer)
      end)
      |> Track.flush_chunk(chunk_offset(state))

    buffer = [buffer: {:output, %Buffer{payload: chunk}}]

    state =
      state
      |> Map.update!(:mdat_size, &(&1 + byte_size(chunk)))
      |> put_in([:pad_to_track, pad_id, :track_data], track_data)

    all_input_pads_with_eos? =
      Enum.all?(ctx.pads, fn {_pad_ref, pad_data} ->
        pad_data.direction == :output or pad_data.end_of_stream?
      end)

    actions =
      if all_input_pads_with_eos?,
        do: buffer ++ finalize_mp4(state) ++ [end_of_stream: :output],
        else: buffer

    {actions, state}
  end

  # --- CAREFUL, REWRITE IT
  defp finalize_mp4(state) do
    movie_box =
      state.pad_to_track
      |> Enum.map(fn {_pad_id, track} -> track.track_data end)
      |> Enum.sort_by(& &1.id)
      |> MovieBox.assemble()

    after_ftyp = {:bof, @ftyp_size}
    mdat_total_size = @mdat_header_size + state.mdat_size

    update_mdat_actions = [
      event: {:output, %File.SeekSinkEvent{position: after_ftyp}},
      buffer: {:output, %Buffer{payload: <<mdat_total_size::32>>}}
    ]

    if state.fast_start do
      moov =
        movie_box
        |> prepare_for_fast_start()
        |> Container.serialize!()

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
end
