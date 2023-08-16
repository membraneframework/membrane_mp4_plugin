defmodule Membrane.MP4.Track do
  @moduledoc """
  A module defining a structure that represents an MPEG-4 track.

  All new samples of a track must be stored in the structure first in order
  to build a sample table of a regular MP4 container. Samples that were stored
  can be flushed later in form of chunks.
  """
  alias __MODULE__.SampleTable
  alias Membrane.AAC
  alias Membrane.MP4.Helper

  @type t :: %__MODULE__{
          id: pos_integer(),
          stream_format: struct(),
          timescale: pos_integer(),
          sample_table: SampleTable.t(),
          duration: non_neg_integer() | nil,
          movie_duration: non_neg_integer() | nil
        }

  @enforce_keys [:id, :stream_format, :timescale, :sample_table]

  defstruct @enforce_keys ++ [duration: nil, movie_duration: nil]

  @spec new(%{id: pos_integer(), stream_format: struct(), timescale: pos_integer()}) ::
          __MODULE__.t()
  def new(%{stream_format: stream_format, timescale: timescale} = config) do
    config =
      Map.put(config, :sample_table, %SampleTable{
        sample_description: stream_format,
        timescale: timescale
      })

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

  @spec finalize(__MODULE__.t(), pos_integer) :: __MODULE__.t()
  def finalize(track, movie_timescale) do
    track
    |> put_durations(movie_timescale)
    |> Map.update!(:sample_table, &SampleTable.reverse/1)
  end

  @spec get_encoding_info(__MODULE__.t()) ::
          {:avc1, %{aot_id: binary(), channels: integer(), frequency: integer()}}
          | {:mp4a, %{profile: binary(), compatibiliy: binary(), level: binary()}}
          | nil

  def get_encoding_info(%__MODULE__{
        stream_format: %Membrane.AAC{
          config: {:esds, esds}
        }
      }) do
    with <<_elementary_stream_id::16, _priority::8, rest::binary>> <- find_esds_section(3, esds),
         <<_section_4::binary-size(13), rest::binary>> <- find_esds_section(4, rest),
         <<aot_id::5, frequency_id::4, channel_config_id::4, _rest::bitstring>> <-
           find_esds_section(5, rest) do
      map = %{
        aot_id: aot_id,
        channels: channel_config_id,
        frequency: AAC.sampling_frequency_id_to_sample_rate(frequency_id)
      }

      {:mp4a, map}
    end
  end

  def get_encoding_info(%__MODULE__{
        stream_format: %Membrane.H264{
          stream_structure: {:avc1, <<1, profile, compatibility, level, _rest::binary>>}
        }
      }) do
    map = %{
      profile: profile,
      compatibility: compatibility,
      level: level
    }

    {:avc1, map}
  end

  def get_encoding_info(_unknown), do: nil

  defp find_esds_section(section_number, payload) do
    case payload do
      <<^section_number::8, 128, 128, 128, section_size::8, payload::binary-size(section_size),
        __rest::binary>> ->
        payload

      <<_other_section::8, 128, 128, 128, section_size::8, _payload::binary-size(section_size),
        rest::binary>> ->
        find_esds_section(section_number, rest)

      _other ->
        nil
    end
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
