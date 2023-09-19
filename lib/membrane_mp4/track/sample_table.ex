defmodule Membrane.MP4.Track.SampleTable do
  @moduledoc """
  A module that defines a structure and functions allowing to store samples,
  assemble them into chunks and flush when needed. Its public functions take
  care of recording information required to build a sample table.

  For performance reasons, the module uses prepends when storing information
  about new samples. To compensate for it, use `#{inspect(&__MODULE__.reverse/1)}`
  when it's known that no more samples will be stored.
  """
  alias Membrane.Buffer

  @type t :: %__MODULE__{
          chunk: [binary],
          chunk_first_dts: non_neg_integer | nil,
          last_dts: non_neg_integer | nil,
          sample_description: struct,
          timescale: pos_integer,
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
          composition_offsets: [
            %{
              sample_offset: Ratio.t(),
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

  @enforce_keys [:timescale]

  defstruct @enforce_keys ++
              [
                chunk: [],
                chunk_first_dts: nil,
                last_dts: nil,
                sample_description: %{},
                sample_count: 0,
                sample_sizes: [],
                sync_samples: [],
                chunk_offsets: [],
                decoding_deltas: [],
                composition_offsets: [],
                samples_per_chunk: []
              ]

  @spec store_sample(__MODULE__.t(), Buffer.t()) :: __MODULE__.t()
  def store_sample(sample_table, buffer) do
    sample_table
    |> maybe_store_first_dts(buffer)
    |> do_store_sample(buffer)
    |> update_decoding_deltas(buffer)
    |> maybe_store_sync_sample(buffer)
    |> store_last_dts(buffer)
  end

  @spec chunk_duration(__MODULE__.t()) :: non_neg_integer
  def chunk_duration(%{chunk_first_dts: nil}), do: 0

  def chunk_duration(sample_table) do
    use Ratio
    sample_table.last_dts - sample_table.chunk_first_dts
  end

  @spec last_dts(__MODULE__.t()) :: integer
  def last_dts(sample_table), do: sample_table.last_dts

  @spec flush_chunk(__MODULE__.t(), non_neg_integer) :: {binary, __MODULE__.t()}
  def flush_chunk(%{chunk: []} = sample_table, _chunk_offset),
    do: {<<>>, sample_table}

  def flush_chunk(sample_table, chunk_offset) do
    chunk = sample_table.chunk

    sample_table =
      sample_table
      |> Map.update!(:chunk_offsets, &[chunk_offset | &1])
      |> update_samples_per_chunk(length(chunk))
      |> Map.merge(%{chunk: [], chunk_first_dts: nil})

    chunk = chunk |> Enum.reverse() |> Enum.join()

    {chunk, sample_table}
  end

  @spec reverse(__MODULE__.t()) :: __MODULE__.t()
  def reverse(sample_table) do
    to_reverse = [
      :sample_sizes,
      :sync_samples,
      :chunk_offsets,
      :decoding_deltas,
      :samples_per_chunk
    ]

    Enum.reduce(to_reverse, sample_table, fn key, sample_table ->
      reversed = sample_table |> Map.fetch!(key) |> Enum.reverse()

      %{sample_table | key => reversed}
    end)
  end

  defp do_store_sample(sample_table, %{payload: payload}),
    do:
      Map.merge(sample_table, %{
        chunk: [payload | sample_table.chunk],
        sample_sizes: [byte_size(payload) | sample_table.sample_sizes],
        sample_count: sample_table.sample_count + 1
      })

  defp maybe_store_first_dts(%{chunk: []} = sample_table, %Buffer{dts: dts}),
    do: %{sample_table | chunk_first_dts: dts}

  defp maybe_store_first_dts(sample_table, _buffer), do: sample_table

  defp update_decoding_deltas(%{last_dts: nil} = sample_table, _buffer) do
    Map.put(sample_table, :decoding_deltas, [%{sample_count: 1, sample_delta: 0}])
  end

  defp update_decoding_deltas(sample_table, %Buffer{dts: dts}) do
    Map.update!(sample_table, :decoding_deltas, fn previous_deltas ->
      use Ratio
      new_delta = dts - sample_table.last_dts

      case previous_deltas do
        # there was only one sample in the sample table - we should assume its delta is
        # equal to the one of the second sample
        [%{sample_count: 1, sample_delta: 0}] ->
          [%{sample_count: 2, sample_delta: new_delta}]

        # the delta did not change, simply increase the counter in the last entry to save space
        [%{sample_count: count, sample_delta: ^new_delta} | rest] ->
          [%{sample_count: count + 1, sample_delta: new_delta} | rest]

        _different_delta_or_empty ->
          [%{sample_count: 1, sample_delta: new_delta} | previous_deltas]
      end
    end)
  end

  defp maybe_store_sync_sample(sample_table, %Buffer{
         metadata: %{h264: %{key_frame?: true}}
       }) do
    Map.update!(sample_table, :sync_samples, &[sample_table.sample_count | &1])
  end

  defp maybe_store_sync_sample(sample_table, _buffer), do: sample_table

  defp store_last_dts(sample_table, %Buffer{dts: dts}),
    do: %{sample_table | last_dts: dts}

  defp update_samples_per_chunk(sample_table, sample_count) do
    Map.update!(sample_table, :samples_per_chunk, fn previous_chunks ->
      case previous_chunks do
        [%{first_chunk: _, sample_count: ^sample_count} | _rest] ->
          previous_chunks

        _different_count ->
          [
            %{first_chunk: length(sample_table.chunk_offsets), sample_count: sample_count}
            | previous_chunks
          ]
      end
    end)
  end
end
