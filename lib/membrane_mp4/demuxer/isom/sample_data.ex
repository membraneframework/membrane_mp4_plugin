defmodule Membrane.MP4.Demuxer.ISOM.SampleData do
  @moduledoc false

  # This module is responsible for generating a description of samples for a given `mdat` box and then
  # generating output buffers using that structure.
  # The samples' description is generated from the the `moov` box, which describes how the data is stored inside the `mdat` box.

  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Container
  alias Membrane.MP4.MovieBox.SampleTableBox
  alias Membrane.MP4.Track.SampleTable

  @enforce_keys [
    :samples,
    :tracks_number,
    :timescales,
    :last_dts,
    :sample_tables
  ]

  defstruct @enforce_keys

  @typedoc """
  A struct containing the descriptions of all the samples inside the `mdat` box, as well
  as some metadata needed to generate the output buffers.
  The samples' descriptions are ordered in the way they are stored inside the `mdat` box.

  As the data is processed, the processed samples' descriptions are removed from the list.
  """
  @type t :: %__MODULE__{
          samples: [
            %{
              size: pos_integer(),
              sample_delta: pos_integer(),
              track_id: pos_integer()
            }
          ],
          timescales: %{
            (track_id :: pos_integer()) => timescale :: pos_integer()
          },
          last_dts: %{
            (track_id :: pos_integer()) => last_dts :: Ratio.t() | nil
          },
          tracks_number: pos_integer(),
          sample_tables: %{(track_id :: pos_integer()) => SampleTable.t()}
        }

  @doc """
  Extracts buffers from the data, based on their description in the sample_data.
  Returns the processed buffers and the remaining data, which doesn't add up to
  a whole sample, and has yet to be parsed.
  """
  @spec get_samples(t, data :: binary()) ::
          {[{Buffer.t(), track_id :: pos_integer()}], rest :: binary, t}
  def get_samples(sample_data, data) do
    {sample_data, rest, buffers} = do_get_samples(sample_data, data, [])

    {buffers, rest, sample_data}
  end

  defp do_get_samples(%{samples: []} = sample_data, data, buffers) do
    {sample_data, data, Enum.reverse(buffers)}
  end

  defp do_get_samples(sample_data, data, buffers) do
    [%{size: size, track_id: track_id} = sample | samples] = sample_data.samples

    if size <= byte_size(data) do
      <<payload::binary-size(size), rest::binary>> = data

      {dts, sample_data} = get_dts(sample_data, sample)

      buffer =
        {%Buffer{
           payload: payload,
           dts: dts
         }, track_id}

      sample_data = %{sample_data | samples: samples}
      do_get_samples(sample_data, rest, [buffer | buffers])
    else
      {sample_data, data, Enum.reverse(buffers)}
    end
  end

  defp get_dts(sample_data, %{sample_delta: delta, track_id: track_id}) do
    use Ratio

    dts =
      case sample_data.last_dts[track_id] do
        nil ->
          0

        last_dts ->
          last_dts +
            delta / sample_data.timescales[track_id] *
              Time.second()
      end

    last_dts = Map.put(sample_data.last_dts, track_id, dts)
    sample_data = %{sample_data | last_dts: last_dts}

    {Ratio.trunc(dts), sample_data}
  end

  @doc """
  Processes the `moov` box and returns a __MODULE__.t() struct, which describes all the samples which are
  present in the `mdat` box.
  The list of samples in the returned struct is used to extract data from the `mdat` box and get output buffers.
  """
  @spec get_sample_data(%{children: boxes :: Container.t()}) :: t
  def get_sample_data(%{children: boxes}) do
    tracks =
      boxes
      |> Enum.filter(fn {type, _content} -> type == :trak end)
      |> Enum.into(%{}, fn {:trak, %{children: boxes}} ->
        {boxes[:tkhd].fields.track_id, boxes}
      end)

    sample_tables =
      Map.new(tracks, fn {track_id, boxes} ->
        {track_id,
         SampleTableBox.unpack(
           boxes[:mdia].children[:minf].children[:stbl],
           boxes[:mdia].children[:mdhd].fields.timescale
         )}
      end)

    # Create a list of chunks in the order in which they are stored in the `mdat` box
    chunk_offsets =
      Enum.flat_map(tracks, fn {track_id, _boxes} ->
        chunks_with_no =
          sample_tables[track_id].chunk_offsets
          |> Enum.with_index(1)

        Enum.map(
          chunks_with_no,
          fn {offset, chunk_no} ->
            %{chunk_no: chunk_no, chunk_offset: offset, track_id: track_id}
          end
        )
      end)
      |> Enum.sort_by(&Map.get(&1, :chunk_offset))

    tracks_data =
      Map.new(sample_tables, fn {track_id, sample_table} ->
        {track_id, Map.take(sample_table, [:decoding_deltas, :sample_sizes, :samples_per_chunk])}
      end)

    # Create a samples' description list for each chunk and flatten it
    {samples, _acc} =
      chunk_offsets
      |> Enum.flat_map_reduce(tracks_data, fn %{track_id: track_id} = chunk, tracks_data ->
        {new_samples, track_data} = get_chunk_samples(chunk, tracks_data[track_id])
        {new_samples, %{tracks_data | track_id => track_data}}
      end)

    timescales =
      Map.new(sample_tables, fn {track_id, sample_table} ->
        {track_id, sample_table.timescale}
      end)

    last_dts = Map.new(tracks, fn {track_id, _boxes} -> {track_id, nil} end)

    %__MODULE__{
      samples: samples,
      tracks_number: map_size(tracks),
      timescales: timescales,
      last_dts: last_dts,
      sample_tables: sample_tables
    }
  end

  defp get_chunk_samples(chunk, track_data) do
    %{chunk_no: chunk_no, track_id: track_id} = chunk

    {track_data, samples_no} = get_samples_no(chunk_no, track_data)

    Enum.map_reduce(1..samples_no, track_data, fn _no, track_data ->
      {sample, track_data} = get_sample_description(track_data)
      sample = Map.put(sample, :track_id, track_id)
      {sample, track_data}
    end)
  end

  defp get_samples_no(chunk_no, %{samples_per_chunk: samples_per_chunk} = track) do
    {samples_per_chunk, samples_no} =
      case samples_per_chunk do
        [
          %{first_chunk: ^chunk_no, samples_per_chunk: samples_no} = first_chunk
          | [%{first_chunk: first_chunk_second} = second_chunk | samples_per_chunk]
        ] ->
          samples_per_chunk =
            if chunk_no + 1 == first_chunk_second do
              [second_chunk | samples_per_chunk]
            else
              [%{first_chunk | first_chunk: chunk_no + 1} | [second_chunk | samples_per_chunk]]
            end

          {samples_per_chunk, samples_no}

        [
          %{first_chunk: ^chunk_no, samples_per_chunk: samples_no} = first_chunk
        ] ->
          {[%{first_chunk | first_chunk: chunk_no + 1}], samples_no}
      end

    {%{track | samples_per_chunk: samples_per_chunk}, samples_no}
  end

  defp get_sample_description(%{decoding_deltas: deltas, sample_sizes: sample_sizes} = track_data) do
    [size | sample_sizes] = sample_sizes

    {delta, deltas} =
      case deltas do
        [%{sample_count: 1, sample_delta: delta} | deltas] ->
          {delta, deltas}

        [%{sample_count: count, sample_delta: delta} | deltas] ->
          {delta, [%{sample_count: count - 1, sample_delta: delta} | deltas]}
      end

    {%{size: size, sample_delta: delta},
     %{track_data | decoding_deltas: deltas, sample_sizes: sample_sizes}}
  end
end
