defmodule Membrane.MP4.Muxer.Track do
  @moduledoc """
  A module defining a structure that represents an MPEG-4 track.
  All new samples of a track must be stored in the structure
  first in order to build a sample table for regular MP4 file.
  The samples can be flushed later as chunks.
  """
  alias __MODULE__.SampleTable

  @type t :: %__MODULE__{
          content: struct,
          height: integer,
          width: integer,
          timescale: integer,
          sample_table: SampleTable.t(),
          id: nil,
          duration: nil,
          movie_duration: nil
        }

  @enforce_keys [:content, :height, :width, :timescale]

  defstruct @enforce_keys ++
              [sample_table: %SampleTable{}, id: nil, duration: nil, movie_duration: nil]

  @spec new(%{
          content: struct,
          height: integer,
          width: integer,
          timescale: integer
        }) :: __MODULE__.t()
  def new(config) do
    %__MODULE__{
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

  @spec current_buffer_size(__MODULE__.t()) :: non_neg_integer
  def current_buffer_size(track), do: length(track.sample_table.samples_buffer)

  @spec flush_chunk(__MODULE__.t(), integer) :: {binary, __MODULE__.t()}
  def flush_chunk(track, chunk_offset) do
    {chunk, sample_table} = SampleTable.flush_chunk(track.sample_table, chunk_offset)

    {chunk, Map.put(track, :sample_table, sample_table)}
  end
end
