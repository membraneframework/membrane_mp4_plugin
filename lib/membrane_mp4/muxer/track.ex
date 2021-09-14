defmodule Membrane.MP4.Muxer.Track do
  @moduledoc false

  alias Membrane.Buffer
  alias Membrane.MP4.Payload.{AVC1, AAC}
  alias __MODULE__.SampleTable

  @type t :: %__MODULE__{
          id: integer,
          kind: :audio | :video,
          height: integer,
          width: integer,
          timescale: integer,
          first_timestamp: integer,
          last_timestamp: integer,
          sample_table: SampleTable.t(),
          buffer: %{
            samples: Qex.t(binary),
            current_size: integer
          }
        }

  @enforce_keys [:id, :kind, :height, :width, :timescale, :sample_table]

  defstruct @enforce_keys ++
              [
                first_timestamp: 0,
                last_timestamp: 0,
                buffer: %{
                  samples: Qex.new(),
                  current_size: 0
                }
              ]

  @spec new(map) :: __MODULE__.t()
  def new(%{
        id: id,
        height: height,
        width: width,
        codec: codec,
        timescale: timescale
      }) do
    %__MODULE__{
      id: id,
      height: height,
      width: width,
      timescale: timescale,
      kind:
        case codec do
          %AAC{} -> :audio
          %AVC1{} -> :video
        end,
      sample_table: %SampleTable{codec: codec}
    }
  end

  @spec store_sample(__MODULE__.t(), %Buffer{}) :: __MODULE__.t()
  def store_sample(track, buffer) do
    track
    |> do_store_sample(buffer)
    |> update_timestamp(buffer)
  end

  @spec flush_chunk(__MODULE__.t(), integer, integer) :: {:not_ready | binary, __MODULE__.t()}
  def flush_chunk(%__MODULE__{} = track, sample_count, chunk_offset) do
    if track.buffer.current_size < sample_count do
      {:not_ready, track}
    else
      do_flush_chunk(track, sample_count, chunk_offset)
    end
  end

  defp do_store_sample(track, buffer) do
    track
    |> Map.update!(
      :buffer,
      &%{
        samples: Qex.push(&1.samples, buffer.payload),
        current_size: &1.current_size + 1
      }
    )
    |> Map.update!(:sample_table, &SampleTable.on_sample_added(&1, buffer))
  end

  defp update_timestamp(%{sample_table: %{sample_count: 0}} = track, %{metadata: %{timestamp: ts}}) do
    Map.merge(track, %{first_timestamp: ts, last_timestamp: ts})
  end

  defp update_timestamp(track, %{metadata: %{timestamp: ts}}) do
    Map.put(track, :last_timestamp, ts)
  end

  defp do_flush_chunk(track, 0, _chunk_offset), do: {<<>>, track}

  defp do_flush_chunk(track, sample_count, chunk_offset) do
    {to_flush, to_keep} = Qex.split(track.buffer.samples, sample_count)

    track =
      track
      |> Map.update!(:buffer, &%{samples: to_keep, current_size: &1.current_size - sample_count})
      |> Map.update!(:sample_table, &SampleTable.on_chunk_flushed(&1, sample_count, chunk_offset))

    out_chunk = Enum.join(to_flush)

    {out_chunk, track}
  end
end
