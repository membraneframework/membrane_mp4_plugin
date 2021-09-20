defmodule Membrane.MP4.Muxer.Track do
  @moduledoc false
  alias __MODULE__.SampleTable

  @type t :: %__MODULE__{
          id: integer,
          content: struct,
          height: integer,
          width: integer,
          timescale: integer,
          sample_table: SampleTable.t()
        }

  @enforce_keys [:id, :content, :height, :width, :timescale]

  defstruct @enforce_keys ++ [sample_table: %SampleTable{}]

  @spec new(%{
          id: integer,
          content: struct,
          height: integer,
          width: integer,
          timescale: integer
        }) :: __MODULE__.t()
  def new(config) do
    %__MODULE__{
      id: config.id,
      content: config.content,
      height: config.height,
      width: config.width,
      timescale: config.timescale
    }
  end

  @spec store_sample(__MODULE__.t(), %Membrane.Buffer{}) :: __MODULE__.t()
  def store_sample(track, buffer) do
    Map.update!(track, :sample_table, &SampleTable.store_sample(&1, buffer))
  end

  @spec flush_chunk(__MODULE__.t(), integer) :: {binary, __MODULE__.t()}
  def flush_chunk(track, chunk_offset) do
    {chunk, sample_table} = SampleTable.flush_chunk(track.sample_table, chunk_offset)

    {chunk, Map.put(track, :sample_table, sample_table)}
  end
end
