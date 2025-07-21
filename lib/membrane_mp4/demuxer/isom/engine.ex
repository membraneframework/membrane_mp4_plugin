defmodule Membrane.MP4.Demuxer.ISOM.Engine do
  @moduledoc """
  A module capable of demuxing streams packed in MP4 ISOM container.

  It is used to demux streams in `Membrane.MP4.Demuxer.ISOM`.
  """

  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SamplesInfo
  alias Membrane.MP4.Demuxer.Sample
  alias Membrane.MP4.Track.SampleTable

  @typedoc """
  A type representing a callback that is used to provide data to the demuxer.
  The callback needs to accept the start position and size (both expressed in bytes) and 
  needs to return a binary of that size.
  """
  @type provide_data_cb :: (start :: non_neg_integer(), size :: pos_integer() -> binary())

  @typedoc """
  A type representing the `#{inspect(__MODULE__)}`
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
            tracks: %{
              pos: non_neg_integer(),
              samples: [
                %{
                  size: pos_integer(),
                  sample_delta: pos_integer(),
                  track_id: pos_integer()
                }
              ]
            },
            samples_info: SamplesInfo.t()
          }

  @enforce_keys [:provide_data_cb]
  defstruct @enforce_keys ++
              [
                cursor: 0,
                box_positions: %{},
                boxes: [],
                samples_info: %{},
                tracks: %{}
              ]

  @max_header_size 16

  @doc """
  Returns new instance of the `#{inspect(__MODULE__)}``.
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
  def(get_tracks_info(state)) do
    state.samples_info.sample_tables
  end

  @doc """
  Reads the sample from given track.
  """
  @spec read_sample(t(), track_id :: pos_integer()) :: {:ok, Sample.t(), t()} | :end_of_stream
  def read_sample(state, track_id) do
    pos = state.tracks[track_id].pos
    sample = state.tracks[track_id].samples |> Enum.at(pos)

    case sample do
      nil ->
        :end_of_stream

      sample ->
        size = sample.size
        offset = sample.sample_offset
        data = state.provide_data_cb.(offset, size)

        dts =
          state.tracks[track_id].samples
          |> Enum.slice(0..pos)
          |> Enum.drop(-1)
          |> Enum.map(& &1.sample_delta)
          |> Enum.sum()

        pts = dts + sample.sample_composition_offset

        state = update_in(state.tracks[track_id].pos, &(&1 + 1))
        pts_ms = pts / state.samples_info.timescales[track_id] * 1000
        dts_ms = dts / state.samples_info.timescales[track_id] * 1000

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

    new_pos =
      state.tracks[track_id].samples
      |> Enum.map_reduce(0, &{{&1, &2}, &1.sample_delta + &2})
      |> elem(0)
      |> Enum.take_while(fn {_sample, cumulative_duration} ->
        cumulative_duration < timestamp_in_native_unit
      end)
      |> length()

    put_in(state.tracks[track_id].pos, new_pos)
  end

  defp find_box(state, box_name) do
    data = state.provide_data_cb.(state.cursor, @max_header_size)
    {:ok, header, _rest} = Container.Header.parse(data)

    if header.name == box_name do
      state =
        update_in(
          state.box_positions,
          &Map.put(&1, box_name, {state.cursor, header.header_size, header.content_size})
        )

      %{state | cursor: 0}
    else
      update_in(state.cursor, &(&1 + header.header_size + header.content_size))
      |> find_box(box_name)
    end
  end

  defp read_box(state, box_name) do
    {box_start, box_header_size, box_content_size} = Map.get(state.box_positions, box_name)

    {[box], _rest} =
      state.provide_data_cb.(box_start, box_header_size + box_content_size) |> Container.parse!()

    update_in(state.boxes, &[box | &1])
  end

  defp resolve_samples(state) do
    {mdat_start, mdat_header_size, _mdat_content_size} = Map.get(state.box_positions, :mdat)

    samples_info =
      SamplesInfo.get_samples_info(
        state.boxes[:moov],
        mdat_start + mdat_header_size
      )

    %{state | samples_info: samples_info}
  end

  defp initialize_tracks(state) do
    tracks =
      Map.keys(state.samples_info.sample_tables)
      |> Enum.map(fn id ->
        # let's keep the list of samples corresponding to given track_id 
        # in the `:tracks` field so that we don't need to filter it out
        # every time we work with samples
        samples = Enum.filter(state.samples_info.samples, &(&1.track_id == id))
        {id, %{pos: 0, samples: samples}}
      end)
      |> Enum.into(%{})

    %{state | tracks: tracks}
  end
end
