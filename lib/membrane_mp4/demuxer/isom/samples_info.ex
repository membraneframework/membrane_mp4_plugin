defmodule Membrane.MP4.Demuxer.ISOM.SamplesInfo do
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
    :sample_tables,
    :mdat_iterator
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
          sample_tables: %{(track_id :: pos_integer()) => SampleTable.t()},
          mdat_iterator: non_neg_integer()
        }

  @doc """
  Extracts buffers from the data, based on their description in the sample_data.
  Returns the processed buffers and the remaining data, which doesn't add up to
  a whole sample, and has yet to be parsed.
  """
  @spec get_samples(t, data :: binary()) ::
          {[{Buffer.t(), track_id :: pos_integer()}], rest :: binary(), t()}
  def get_samples(samples_info, data) do
    {samples_info, rest, buffers} =
      do_get_samples(samples_info, data, [])

    {buffers, rest, samples_info}
  end

  defp do_get_samples(%{samples: []} = samples_info, data, buffers) do
    {samples_info, data, Enum.reverse(buffers)}
  end

  defp do_get_samples(samples_info, data, buffers) do
    [%{size: size, track_id: track_id, sample_offset: sample_offset} = sample | samples] =
      samples_info.samples

    to_skip = sample_offset - samples_info.mdat_iterator

    case data do
      <<_to_skip::binary-size(to_skip), payload::binary-size(size), rest::binary>> ->
        {dts, pts, samples_info} = get_dts_and_pts(samples_info, sample)

        buffer =
          {%Buffer{
             payload: payload,
             dts: dts,
             pts: pts
           }, track_id}

        samples_info = %{samples_info | samples: samples}

        do_get_samples(
          %{samples_info | mdat_iterator: samples_info.mdat_iterator + to_skip + size},
          rest,
          [buffer | buffers]
        )

      _other ->
        {samples_info, data, Enum.reverse(buffers)}
    end
  end

  defp get_dts_and_pts(samples_info, %{
         sample_delta: delta,
         track_id: track_id,
         sample_composition_offset: sample_composition_offset
       }) do
    use Numbers, overload_operators: true
    timescale = samples_info.timescales[track_id]

    {dts, pts} =
      case samples_info.last_dts[track_id] do
        nil ->
          {0, 0}

        last_dts ->
          {last_dts + scalify(delta, timescale),
           last_dts +
             scalify(delta + sample_composition_offset, timescale)}
      end

    last_dts = Map.put(samples_info.last_dts, track_id, dts)
    samples_info = %{samples_info | last_dts: last_dts}

    {Ratio.trunc(dts), Ratio.trunc(pts), samples_info}
  end

  defp scalify(delta, timescale) do
    delta / timescale * Time.second()
  end

  @doc """
  Processes the `moov` box and returns a __MODULE__.t() struct, which describes all the samples which are
  present in the `mdat` box.
  The list of samples in the returned struct is used to extract data from the `mdat` box and get output buffers.
  """
  @spec get_samples_info(%{children: boxes :: Container.t()}, non_neg_integer()) :: t
  def get_samples_info(%{children: boxes}, mdat_beginning) do
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
        {track_id,
         Map.take(sample_table, [
           :decoding_deltas,
           :sample_sizes,
           :samples_per_chunk,
           :composition_offsets,
           :chunk_offset
         ])}
      end)

    # Create a samples' description list for each chunk and flatten it
    {samples, _acc} =
      chunk_offsets
      |> Enum.flat_map_reduce(tracks_data, fn %{track_id: track_id} = chunk, tracks_data ->
        {new_samples, {track_data, _sample_offset}} =
          get_chunk_samples(chunk, tracks_data[track_id])

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
      sample_tables: sample_tables,
      mdat_iterator: mdat_beginning
    }
  end

  defp get_chunk_samples(chunk, track_data) do
    %{chunk_no: chunk_no, track_id: track_id, chunk_offset: chunk_offset} = chunk

    {track_data, samples_no} = get_samples_no(chunk_no, track_data)

    Enum.map_reduce(1..samples_no, {track_data, chunk_offset}, fn _no,
                                                                  {track_data, sample_offset} ->
      {sample, track_data} = get_sample_description(track_data)

      sample =
        Map.merge(sample, %{
          track_id: track_id,
          chunk_offset: chunk_offset,
          sample_offset: sample_offset
        })

      {sample, {track_data, sample_offset + sample.size}}
    end)
  end

  defp get_samples_no(chunk_no, %{samples_per_chunk: samples_per_chunk} = track) do
    {samples_per_chunk, samples_no} =
      case samples_per_chunk do
        [
          %{first_chunk: ^chunk_no, samples_per_chunk: samples_no} = current_chunk_group,
          %{first_chunk: next_chunk_group_no} = next_chunk_group | samples_per_chunk
        ] ->
          samples_per_chunk =
            if chunk_no + 1 == next_chunk_group_no do
              # If the currently processed chunk is the last one in its group
              # we remove this chunk group description
              [next_chunk_group | samples_per_chunk]
            else
              [
                %{current_chunk_group | first_chunk: chunk_no + 1},
                next_chunk_group | samples_per_chunk
              ]
            end

          {samples_per_chunk, samples_no}

        [
          %{first_chunk: ^chunk_no, samples_per_chunk: samples_no} = current_chunk_group
        ] ->
          {[%{current_chunk_group | first_chunk: chunk_no + 1}], samples_no}
      end

    {%{track | samples_per_chunk: samples_per_chunk}, samples_no}
  end

  defp get_sample_description(
         %{
           decoding_deltas: deltas,
           sample_sizes: sample_sizes,
           composition_offsets: composition_offsets
         } = track_data
       ) do
    [size | sample_sizes] = sample_sizes

    # TODO - these two clauses could be unified so that not to repeat the code
    {delta, deltas} =
      case deltas do
        [%{sample_count: 1, sample_delta: delta} | deltas] ->
          {delta, deltas}

        [%{sample_count: count, sample_delta: delta} | deltas] ->
          {delta, [%{sample_count: count - 1, sample_delta: delta} | deltas]}
      end

    {sample_composition_offset, composition_offsets} =
      case composition_offsets do
        [%{sample_count: 1, sample_composition_offset: offset} | composition_offsets] ->
          {offset, composition_offsets}

        [%{sample_count: count, sample_composition_offset: offset} | composition_offsets] ->
          {offset,
           [%{sample_count: count - 1, sample_composition_offset: offset} | composition_offsets]}
      end

    {%{
       size: size,
       sample_delta: delta,
       sample_composition_offset: sample_composition_offset
     },
     %{
       track_data
       | decoding_deltas: deltas,
         sample_sizes: sample_sizes,
         composition_offsets: composition_offsets
     }}
  end
end
