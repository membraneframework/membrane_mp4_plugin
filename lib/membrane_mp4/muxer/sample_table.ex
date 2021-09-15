defmodule Membrane.MP4.Muxer.Track.SampleTable do
  @moduledoc false

  @type t :: %__MODULE__{
          sample_count: integer,
          chunks_flushed: integer,
          last_timestamp: integer,
          sample_sizes: [integer],
          sync_samples: [integer],
          chunk_offsets: [integer],
          decoding_deltas: [
            %{
              sample_delta: Ratio.t(),
              sample_count: integer
            }
          ],
          samples_per_chunk: [
            %{
              first_chunk: integer,
              sample_count: integer
            }
          ]
        }

  defstruct sample_count: 0,
            chunks_flushed: 0,
            last_timestamp: 0,
            sample_sizes: [],
            sync_samples: [],
            chunk_offsets: [],
            decoding_deltas: [],
            samples_per_chunk: []

  @spec on_sample_added(__MODULE__.t(), %Membrane.Buffer{}) :: __MODULE__.t()
  def on_sample_added(sample_table, buffer) do
    sample_table
    |> add_sample_info(buffer)
    |> update_decoding_deltas(buffer)
    |> maybe_store_sync_sample(buffer)
  end

  @spec on_chunk_flushed(__MODULE__.t(), integer, integer) :: __MODULE__.t()
  def on_chunk_flushed(sample_table, sample_count, offset) do
    sample_table
    |> add_chunk_info(offset)
    |> update_samples_per_chunk(sample_count)
  end

  defp add_sample_info(sample_table, %{payload: payload}) do
    sample_table
    |> Map.update!(:sample_count, &(&1 + 1))
    |> Map.update!(:sample_sizes, &[byte_size(payload) | &1])
  end

  defp update_decoding_deltas(sample_table, %{metadata: %{timestamp: timestamp}}) do
    sample_table
    |> Map.update!(:decoding_deltas, fn previous_deltas ->
      use Ratio
      new_delta = timestamp - sample_table.last_timestamp

      case previous_deltas do
        [%{sample_count: 1, sample_delta: _}] ->
          [%{sample_count: 2, sample_delta: new_delta}]

        [%{sample_count: count, sample_delta: ^new_delta} | rest] ->
          [%{sample_count: count + 1, sample_delta: new_delta} | rest]

        _ ->
          [%{sample_count: 1, sample_delta: new_delta} | previous_deltas]
      end
    end)
    |> Map.put(:last_timestamp, timestamp)
  end

  defp maybe_store_sync_sample(sample_table, %{metadata: %{mp4_payload: %{key_frame?: true}}}) do
    Map.update!(sample_table, :sync_samples, &[sample_table.sample_count | &1])
  end

  defp maybe_store_sync_sample(sample_table, _buffer), do: sample_table

  defp add_chunk_info(sample_table, offset) do
    sample_table
    |> Map.update!(:chunks_flushed, &(&1 + 1))
    |> Map.update!(:chunk_offsets, &[offset | &1])
  end

  defp update_samples_per_chunk(sample_table, sample_count) do
    Map.update!(sample_table, :samples_per_chunk, fn previous_chunks ->
      case previous_chunks do
        [%{first_chunk: _, sample_count: ^sample_count} | _rest] ->
          previous_chunks

        _ ->
          [
            %{first_chunk: sample_table.chunks_flushed, sample_count: sample_count}
            | previous_chunks
          ]
      end
    end)
  end
end
