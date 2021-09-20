defmodule Membrane.MP4.Muxer.Track.SampleTable do
  @moduledoc false

  @type t :: %__MODULE__{
          last_timestamp: integer,
          samples_buffer: [binary],
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

  defstruct last_timestamp: 0,
            samples_buffer: [],
            sample_sizes: [],
            sync_samples: [],
            chunk_offsets: [],
            decoding_deltas: [],
            samples_per_chunk: []

  @spec store_sample(__MODULE__.t(), %Membrane.Buffer{}) :: __MODULE__.t()
  def store_sample(sample_table, buffer) do
    sample_table
    |> Map.update!(:samples_buffer, &[buffer.payload | &1])
    |> Map.update!(:sample_sizes, &[byte_size(buffer.payload) | &1])
    |> update_decoding_deltas(buffer)
    |> maybe_store_sync_sample(buffer)
  end

  @spec flush_chunk(__MODULE__.t(), integer) :: {binary, __MODULE__.t()}
  def flush_chunk(sample_table, chunk_offset) do
    samples_in_chunk = length(sample_table.samples_buffer)

    if samples_in_chunk > 0 do
      {chunk, sample_table} =
        sample_table
        |> Map.update!(:chunk_offsets, &[chunk_offset | &1])
        |> Map.get_and_update!(:samples_buffer, fn buffer ->
          {buffer |> Enum.reverse() |> Enum.join(), []}
        end)

      {chunk, update_samples_per_chunk(sample_table, samples_in_chunk)}
    else
      {<<>>, sample_table}
    end
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
    Map.update!(sample_table, :sync_samples, &[length(sample_table.sample_sizes) | &1])
  end

  defp maybe_store_sync_sample(sample_table, _buffer), do: sample_table

  defp update_samples_per_chunk(sample_table, sample_count) do
    Map.update!(sample_table, :samples_per_chunk, fn previous_chunks ->
      case previous_chunks do
        [%{first_chunk: _, sample_count: ^sample_count} | _rest] ->
          previous_chunks

        _ ->
          [
            %{first_chunk: length(sample_table.chunk_offsets), sample_count: sample_count}
            | previous_chunks
          ]
      end
    end)
  end
end
