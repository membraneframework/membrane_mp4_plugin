defmodule Membrane.MP4.Demuxer.ISOM.SampleData do
  @moduledoc false
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

  @spec get_sample_data(%{children: boxes :: Container.t()}) :: t
  def get_sample_data(%{children: boxes}) do
    tracks =
      boxes
      |> Enum.filter(fn {type, _content} -> type == :trak end)
      |> Enum.into(%{}, fn {:trak, %{children: boxes}} ->
        {boxes[:tkhd].fields.track_id, boxes}
      end)

    sample_tables =
      Enum.map(tracks, fn {track_id, boxes} ->
        {track_id,
         SampleTableBox.unpack(
           boxes[:mdia].children[:minf].children[:stbl],
           boxes[:mdia].children[:mdhd].fields.timescale
         )}
      end)
      |> Enum.into(%{})

    chunk_offsets =
      Enum.flat_map(tracks, fn {track_id, _boxes} ->
        offsets = sample_tables[track_id].chunk_offsets
        chunks_with_no = [Enum.to_list(1..length(offsets)), offsets] |> List.zip()

        Enum.map(
          chunks_with_no,
          fn {chunk_no, offset} ->
            %{chunk_no: chunk_no, chunk_offset: offset, track_id: track_id}
          end
        )
      end)
      |> Enum.sort_by(&Map.get(&1, :chunk_offset), :asc)

    acc =
      Enum.map(sample_tables, fn {track_id, sample_table} ->
        {track_id, Map.take(sample_table, [:decoding_deltas, :sample_sizes, :samples_per_chunk])}
      end)
      |> Enum.into(%{})

    samples =
      Enum.reduce(chunk_offsets, {[], acc}, fn %{track_id: track_id} = chunk, {samples, acc} ->
        {new_samples, track_acc} = get_chunk_samples(chunk, acc[track_id])
        {[new_samples | samples], %{acc | track_id => track_acc}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> List.flatten()

    timescales =
      Enum.map(sample_tables, fn {track_id, sample_table} ->
        {track_id, sample_table.timescale}
      end)
      |> Enum.into(%{})

    last_dts =
      Enum.map(tracks, fn {track_id, _boxes} -> {track_id, nil} end)
      |> Enum.into(%{})

    %__MODULE__{
      samples: samples,
      tracks_number: map_size(tracks),
      timescales: timescales,
      last_dts: last_dts,
      sample_tables: sample_tables
    }
  end

  defp get_chunk_samples(chunk, acc) do
    %{chunk_no: chunk_no, track_id: track_id} = chunk

    samples_no = get_samples_no(chunk_no, acc.samples_per_chunk)

    {samples, acc} =
      Enum.reduce(1..samples_no, {[], acc}, fn _no, {samples, acc} ->
        {sample, acc} = get_sample(acc)
        sample = Map.put(sample, :track_id, track_id)
        {[sample | samples], acc}
      end)

    {Enum.reverse(samples), acc}
  end

  defp get_samples_no(chunk_no, samples_per_chunk) do
    Enum.reverse(samples_per_chunk)
    |> Enum.find_value(fn %{first_chunk: first_chunk, samples_per_chunk: samples_no} ->
      if first_chunk <= chunk_no, do: samples_no
    end)
  end

  defp get_sample(%{decoding_deltas: deltas, sample_sizes: sample_sizes} = acc) do
    [size | sample_sizes] = sample_sizes

    {delta, deltas} =
      case hd(deltas) do
        %{sample_count: 1, sample_delta: delta} ->
          {delta, tl(deltas)}

        %{sample_count: count, sample_delta: delta} ->
          {delta, [%{sample_count: count - 1, sample_delta: delta} | tl(deltas)]}
      end

    {%{size: size, sample_delta: delta},
     %{acc | decoding_deltas: deltas, sample_sizes: sample_sizes}}
  end
end
