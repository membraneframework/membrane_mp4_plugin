defmodule Membrane.MP4.Muxer.Track.SampleTable do
  alias Membrane.Buffer
  alias Membrane.MP4.Payload.AVC1

  @type t :: %__MODULE__{
          codec: struct,
          sample_count: integer,
          chunks_flushed: integer,
          sample_sizes: [integer],
          keyframes: [integer],
          last_dts: integer,
          decoding_deltas: [
            %{
              sample_count: integer,
              sample_delta: Ratio.t()
            }
          ],
          chunk_offsets: [integer],
          samples_per_chunk: [
            %{
              first_chunk: integer,
              sample_count: integer
            }
          ]
        }

  @enforce_keys [:codec]

  defstruct @enforce_keys ++
              [
                sample_count: 0,
                chunks_flushed: 0,
                sample_sizes: [],
                keyframes: [],
                last_dts: 0,
                decoding_deltas: [],
                chunk_offsets: [],
                samples_per_chunk: []
              ]

  @spec on_sample_added(__MODULE__.t(), %Buffer{}) :: __MODULE__.t()
  def on_sample_added(sample_table, buffer) do
    sample_table
    |> Map.update!(:sample_count, &(&1 + 1))
    |> Map.update!(:sample_sizes, &[byte_size(buffer.payload) | &1])
    |> maybe_store_keyframe(buffer)
    |> update_decoding_deltas(buffer)
  end

  @spec on_chunk_flushed(__MODULE__.t(), integer, integer) :: __MODULE__.t()
  def on_chunk_flushed(sample_table, sample_count, offset) do
    sample_table
    |> Map.update!(:samples_per_chunk, fn previous_chunks ->
      case previous_chunks do
        [%{first_chunk: _, sample_count: ^sample_count} | _rest] ->
          previous_chunks

        _ ->
          [
            %{first_chunk: sample_table.chunks_flushed + 1, sample_count: sample_count}
            | previous_chunks
          ]
      end
    end)
    |> Map.update!(:chunks_flushed, &(&1 + 1))
    |> Map.update!(:chunk_offsets, &[offset | &1])
  end

  defp maybe_store_keyframe(%{codec: %AVC1{}} = sample_table, %{
         metadata: %{mp4_payload: %{key_frame?: true}}
       }) do
    Map.update!(sample_table, :keyframes, &[sample_table.sample_count | &1])
  end

  defp maybe_store_keyframe(sample_table, _buffer), do: sample_table

  defp update_decoding_deltas(%{codec: %AVC1{}} = sample_table, %{metadata: %{dts: dts}}) do
    sample_table
    |> Map.update!(:decoding_deltas, fn previous_deltas ->
      use Ratio
      new_delta = dts - sample_table.last_dts

      case previous_deltas do
        [%{sample_count: count, sample_delta: ^new_delta} | rest] ->
          [%{sample_count: count + 1, sample_delta: new_delta} | rest]

        _ ->
          [%{sample_count: 1, sample_delta: new_delta} | previous_deltas]
      end
    end)
    |> Map.put(:last_dts, dts)
  end

  defp update_decoding_deltas(sample_table, _buffer) do
    sample_table
  end
end
