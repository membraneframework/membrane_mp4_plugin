defmodule Membrane.MP4.Demuxer.ISOM.Engine do
  @moduledoc """
  A module capable of demuxing streams packed in MP4 ISOM container.

  It is used to demux streams in `Membrane.MP4.Demuxer.ISOM`.
  """

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema
  alias Membrane.MP4.Demuxer.ISOM.SamplesInfo

  alias Membrane.MP4.Demuxer.Sample
  alias Membrane.MP4.Track.SampleTable

  @typedoc """
  A type representing a callback that is used to provide data to the demuxer.
  The callback needs to accept the start position and size (both expressed in bytes) and 
  needs to return a binary of that size.
  """
  @type provide_data_cb :: (start :: non_neg_integer(), size :: pos_integer(), state :: any() ->
                              {data :: binary(), state :: any()})

  @typedoc """
  A type representing the `#{inspect(__MODULE__)}`.
  """
  @opaque t :: %__MODULE__{
            provide_data_cb: provide_data_cb(),
            cursor: non_neg_integer(),
            box_positions: %{
              Container.box_name_t() =>
                {offset :: non_neg_integer(), header_size :: pos_integer(),
                 content_size :: pos_integer()}
            },
            boxes: Container.t(),
            tracks: %{(track_id :: pos_integer()) => track()},
            samples_info: %{
              sample_tables: %{(track_id :: pos_integer()) => SampleTable.t()},
              timescales: %{(track_id :: pos_integer()) => pos_integer()}
            },
            provider_state: any()
          }

  # Samples are expanded one chunk at a time from the compact sample tables, so the memory
  # footprint does not grow with the number of samples in the file.
  @typedoc false
  @type track :: %{
          track_id: pos_integer(),
          track_data: map(),
          chunk_offsets: [non_neg_integer()],
          next_chunk_no: pos_integer(),
          samples: [map()],
          next_dts: non_neg_integer()
        }

  @enforce_keys [:provide_data_cb]
  defstruct @enforce_keys ++
              [
                cursor: 0,
                box_positions: %{},
                boxes: [],
                tracks: %{},
                samples_info: %{},
                provider_state: nil
              ]

  @max_header_size 16
  @schema Schema.Default.schema()

  @doc """
  Returns new instance of the `#{inspect(__MODULE__)}`.
  """
  @spec new(provide_data_cb()) :: t()
  def new(provide_data_cb) do
    %__MODULE__{provide_data_cb: provide_data_cb}
    |> find_box(:moov)
    |> read_box(:moov)
    |> find_box(:mdat)
    |> resolve_samples()
    |> initialize_tracks()
  end

  @doc """
  Returns a map describing tracks found in the MP4 file.
  """
  @spec get_tracks_info(t()) :: %{(track_id :: pos_integer()) => SampleTable.t()}
  def get_tracks_info(state) do
    state.samples_info.sample_tables
  end

  @doc """
  Reads the sample from given track.
  """
  @spec read_sample(t(), track_id :: pos_integer()) :: {:ok, Sample.t(), t()} | :end_of_stream
  def read_sample(state, track_id) do
    case next_sample(state.tracks[track_id]) do
      :end_of_stream ->
        :end_of_stream

      {sample, track} ->
        {data, provider_state} =
          state.provide_data_cb.(sample.sample_offset, sample.size, state.provider_state)

        timescale = state.samples_info.timescales[track_id]
        dts = track.next_dts
        pts = dts + sample.sample_composition_offset
        pts_ms = (pts / timescale * 1000) |> round()
        dts_ms = (dts / timescale * 1000) |> round()

        state = %{
          state
          | provider_state: provider_state,
            tracks:
              Map.put(state.tracks, track_id, %{track | next_dts: dts + sample.sample_delta})
        }

        {:ok, %Sample{payload: data, pts: pts_ms, dts: dts_ms, track_id: track_id}, state}
    end
  end

  @doc """
  Moves the track cursor so that it points at the first sample with DTS 
  equal or greater than provided `timestamp_ms`.
  """
  @spec seek_in_samples(t(), track_id :: pos_integer(), timestamp_ms :: non_neg_integer()) :: t()
  def seek_in_samples(state, track_id, timestamp_ms) do
    timestamp_in_native_unit = timestamp_ms / 1000 * state.samples_info.timescales[track_id]
    track = skip_samples(state.tracks[track_id], timestamp_in_native_unit)
    put_in(state.tracks[track_id], track)
  end

  defp skip_samples(%{next_dts: next_dts} = track, timestamp) when next_dts < timestamp do
    case next_sample(track) do
      {sample, track} ->
        skip_samples(%{track | next_dts: next_dts + sample.sample_delta}, timestamp)

      :end_of_stream ->
        track
    end
  end

  defp skip_samples(track, _timestamp), do: track

  defp next_sample(%{samples: [sample | samples]} = track),
    do: {sample, %{track | samples: samples}}

  defp next_sample(%{samples: [], chunk_offsets: []}), do: :end_of_stream

  defp next_sample(%{samples: [], chunk_offsets: [chunk_offset | chunk_offsets]} = track) do
    chunk = %{chunk_no: track.next_chunk_no, track_id: track.track_id, chunk_offset: chunk_offset}

    {samples, {track_data, _next_sample_offset}} =
      SamplesInfo.get_chunk_samples(chunk, track.track_data)

    next_sample(%{
      track
      | samples: samples,
        chunk_offsets: chunk_offsets,
        next_chunk_no: track.next_chunk_no + 1,
        track_data: track_data
    })
  end

  defp find_box(state, box_name) do
    {data, provider_state} =
      state.provide_data_cb.(state.cursor, @max_header_size, state.provider_state)

    state = put_in(state.provider_state, provider_state)

    case Container.Header.parse(data, @schema) do
      {:ok, %{name: ^box_name} = header, _rest} ->
        state =
          update_in(
            state.box_positions,
            &Map.put(&1, box_name, {state.cursor, header.header_size, header.content_size})
          )

        %{state | cursor: 0}

      {:ok, header, _rest} ->
        update_in(state.cursor, &(&1 + header.header_size + header.content_size))
        |> find_box(box_name)

      {:error, {:unknown_box, _name, header_size, content_size}} ->
        update_in(state.cursor, &(&1 + header_size + content_size))
        |> find_box(box_name)
    end
  end

  defp read_box(state, box_name) do
    {box_start, box_header_size, box_content_size} = Map.get(state.box_positions, box_name)

    {data, provider_state} =
      state.provide_data_cb.(box_start, box_header_size + box_content_size, state.provider_state)

    state = put_in(state.provider_state, provider_state)

    {[box], _rest} = Container.parse!(data, @schema)

    update_in(state.boxes, &[box | &1])
  end

  defp resolve_samples(state) do
    sample_tables = SamplesInfo.get_sample_tables(state.boxes[:moov])
    timescales = Map.new(sample_tables, fn {track_id, table} -> {track_id, table.timescale} end)
    %{state | samples_info: %{sample_tables: sample_tables, timescales: timescales}}
  end

  defp initialize_tracks(state) do
    tracks =
      Map.new(state.samples_info.sample_tables, fn {track_id, table} ->
        {track_id,
         %{
           track_id: track_id,
           track_data:
             Map.take(table, [
               :decoding_deltas,
               :sample_sizes,
               :samples_per_chunk,
               :composition_offsets
             ]),
           chunk_offsets: table.chunk_offsets,
           next_chunk_no: 1,
           samples: [],
           next_dts: 0
         }}
      end)

    %{state | tracks: tracks}
  end
end
