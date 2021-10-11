defmodule Membrane.MP4.Muxer.Track.SampleTable do
  @moduledoc """
  A module that defines a structure and functions allowing to store
  samples, assemble them into chunks and flush when needed. Its
  public functions take care of recording information required to
  build a sample table.
  """

  @type t :: %__MODULE__{
          chunk: %{
            samples: [binary],
            first_timestamp: non_neg_integer,
            last_timestamp: non_neg_integer
          },
          sample_count: non_neg_integer,
          sample_sizes: [pos_integer],
          sync_samples: [pos_integer],
          chunk_offsets: [non_neg_integer],
          decoding_deltas: [
            %{
              sample_delta: Ratio.t(),
              sample_count: pos_integer
            }
          ],
          samples_per_chunk: [
            %{
              first_chunk: pos_integer,
              sample_count: pos_integer
            }
          ]
        }

  defstruct chunk: %{
              samples: [],
              first_timestamp: 0,
              last_timestamp: 0
            },
            sample_count: 0,
            sample_sizes: [],
            sync_samples: [],
            chunk_offsets: [],
            decoding_deltas: [],
            samples_per_chunk: []

  @spec store_sample(__MODULE__.t(), Membrane.Buffer.t()) :: __MODULE__.t()
  def store_sample(sample_table, buffer) do
    sample_table
    |> maybe_store_first_timestamp(buffer)
    |> do_store_sample(buffer)
    |> update_decoding_deltas(buffer)
    |> maybe_store_sync_sample(buffer)
    |> store_last_timestamp(buffer)
  end

  @spec chunk_duration(__MODULE__.t()) :: non_neg_integer
  def chunk_duration(%{chunk: %{samples: []}}), do: 0

  def chunk_duration(%{chunk: chunk}) do
    use Ratio
    chunk.last_timestamp - chunk.first_timestamp
  end

  @spec flush_chunk(__MODULE__.t(), non_neg_integer) :: {binary, __MODULE__.t()}
  def flush_chunk(%{chunk: %{samples: []}} = sample_table, _chunk_offset),
    do: {<<>>, sample_table}

  def flush_chunk(%{chunk: %{samples: samples}} = sample_table, chunk_offset) do
    sample_table =
      sample_table
      |> Map.update!(:chunk, &Map.put(&1, :samples, []))
      |> Map.update!(:chunk_offsets, &[chunk_offset | &1])
      |> update_samples_per_chunk(length(samples))

    chunk = samples |> Enum.reverse() |> Enum.join()

    {chunk, sample_table}
  end

  defp do_store_sample(sample_table, %{payload: payload}) do
    sample_table
    |> Map.update!(:chunk, fn chunk -> Map.update!(chunk, :samples, &[payload | &1]) end)
    |> Map.update!(:sample_sizes, &[byte_size(payload) | &1])
    |> Map.update!(:sample_count, &(&1 + 1))
  end

  defp maybe_store_first_timestamp(%{chunk: %{samples: []}} = sample_table, %{
         metadata: %{timestamp: timestamp}
       }) do
    Map.update!(sample_table, :chunk, &Map.put(&1, :first_timestamp, timestamp))
  end

  defp maybe_store_first_timestamp(sample_table, _buffer), do: sample_table

  defp update_decoding_deltas(sample_table, %{metadata: %{timestamp: timestamp}}) do
    Map.update!(sample_table, :decoding_deltas, fn previous_deltas ->
      use Ratio
      new_delta = timestamp - sample_table.chunk.last_timestamp

      case previous_deltas do
        # there was only one sample in the sample table - we should assume its delta is
        # equal to the one of the second sample
        [%{sample_count: 1, sample_delta: _}] ->
          [%{sample_count: 2, sample_delta: new_delta}]

        # the delta did not change, simply increase the counter in the last entry to save space
        [%{sample_count: count, sample_delta: ^new_delta} | rest] ->
          [%{sample_count: count + 1, sample_delta: new_delta} | rest]

        # the delta is different or this is the first sample, we need to create a new entry
        _ ->
          [%{sample_count: 1, sample_delta: new_delta} | previous_deltas]
      end
    end)
  end

  defp maybe_store_sync_sample(sample_table, %{metadata: %{mp4_payload: %{key_frame?: true}}}) do
    Map.update!(sample_table, :sync_samples, &[sample_table.sample_count | &1])
  end

  defp maybe_store_sync_sample(sample_table, _buffer), do: sample_table

  defp store_last_timestamp(sample_table, %{metadata: %{timestamp: timestamp}}) do
    Map.update!(sample_table, :chunk, &Map.put(&1, :last_timestamp, timestamp))
  end

  defp update_samples_per_chunk(sample_table, sample_count) do
    Map.update!(sample_table, :samples_per_chunk, fn previous_chunks ->
      case previous_chunks do
        # the sample count of new chunk is identical, no action needed
        [%{first_chunk: _, sample_count: ^sample_count} | _rest] ->
          previous_chunks

        # we provide information that starting from this chunk, sample count per chunk changes
        _ ->
          [
            %{first_chunk: length(sample_table.chunk_offsets), sample_count: sample_count}
            | previous_chunks
          ]
      end
    end)
  end
end
