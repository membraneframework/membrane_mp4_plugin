defmodule Membrane.MP4.Muxer.Track do
  @moduledoc """
  A module defining a structure that represents an MPEG-4 track.
  All new samples of a track must be stored in the structure first
  in order to build a sample table of a regular MP4 container.
  Samples that were stored can be flushed later in form of chunks.
  """
  alias Membrane.MP4.Muxer.Helper
  alias __MODULE__.SampleTable

  @type t :: %__MODULE__{
          content: struct,
          height: non_neg_integer,
          width: non_neg_integer,
          timescale: pos_integer,
          sample_table: SampleTable.t(),
          id: pos_integer | nil,
          duration: non_neg_integer | nil,
          movie_duration: non_neg_integer | nil
        }

  @enforce_keys [:content, :height, :width, :timescale]

  defstruct @enforce_keys ++
              [sample_table: %SampleTable{}, id: nil, duration: nil, movie_duration: nil]

  @spec new(%{
          content: struct,
          height: non_neg_integer,
          width: non_neg_integer,
          timescale: pos_integer
        }) :: __MODULE__.t()
  def new(config) do
    struct!(__MODULE__, config)
  end

  @spec store_sample(__MODULE__.t(), Membrane.Buffer.t()) :: __MODULE__.t()
  def store_sample(track, buffer) do
    Map.update!(track, :sample_table, &SampleTable.store_sample(&1, buffer))
  end

  @spec current_chunk_duration(__MODULE__.t()) :: non_neg_integer
  def current_chunk_duration(%{sample_table: sample_table}) do
    SampleTable.chunk_duration(sample_table)
  end

  @spec flush_chunk(__MODULE__.t(), non_neg_integer) :: {binary, __MODULE__.t()}
  def flush_chunk(track, chunk_offset) do
    {chunk, sample_table} = SampleTable.flush_chunk(track.sample_table, chunk_offset)

    {chunk, %{track | sample_table: sample_table}}
  end

  @spec finalize(__MODULE__.t(), pos_integer, pos_integer) :: __MODULE__.t()
  def finalize(track, id, movie_timescale) do
    track
    |> Map.put(:id, id)
    |> put_durations(movie_timescale)
    |> Map.update!(:sample_table, &SampleTable.reverse/1)
  end

  defp put_durations(track, movie_timescale) do
    use Ratio

    duration =
      track.sample_table.decoding_deltas
      |> Enum.reduce(0, &(&1.sample_count * &1.sample_delta + &2))

    %{
      track
      | duration: Helper.timescalify(duration, track.timescale),
        movie_duration: Helper.timescalify(duration, movie_timescale)
    }
  end
end
