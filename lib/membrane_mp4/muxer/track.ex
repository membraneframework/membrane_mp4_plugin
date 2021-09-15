defmodule Membrane.MP4.Muxer.Track do
  @moduledoc false

  alias Membrane.Buffer
  alias __MODULE__.SampleTable

  @type t :: %__MODULE__{
          id: integer,
          format: struct,
          height: integer,
          width: integer,
          timescale: integer,
          buffer: %{
            samples: Qex.t(binary),
            current_size: integer
          },
          sample_table: SampleTable.t()
        }

  @enforce_keys [:id, :format, :height, :width, :timescale]

  defstruct @enforce_keys ++
              [
                buffer: %{
                  samples: Qex.new(),
                  current_size: 0
                },
                sample_table: %SampleTable{}
              ]

  @spec new(%{
          id: integer,
          codec: struct,
          height: integer,
          width: integer,
          timescale: integer
        }) :: __MODULE__.t()
  def new(config) do
    %__MODULE__{
      id: config.id,
      format: config.codec,
      height: config.height,
      width: config.width,
      timescale: config.timescale
    }
  end

  @spec store_sample(__MODULE__.t(), %Buffer{}) :: __MODULE__.t()
  def store_sample(track, buffer) do
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

  @spec flush_chunk(__MODULE__.t(), integer) :: {binary, __MODULE__.t()}
  def flush_chunk(track, chunk_offset) do
    do_flush_chunk(track, track.buffer.current_size, chunk_offset)
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
