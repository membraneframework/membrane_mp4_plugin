defmodule Membrane.MP4.Track do
  @moduledoc """
  A module defining a structure that represents an MPEG-4 track.

  All new samples of a track must be stored in the structure first in order
  to build a sample table of a regular MP4 container. Samples that were stored
  can be flushed later in form of chunks.
  """
  require Membrane.H264
  alias __MODULE__.SampleTable
  alias Membrane.{AAC, H264}
  alias Membrane.MP4.Helper

  @type t :: %__MODULE__{
          id: pos_integer(),
          stream_format: struct(),
          timescale: pos_integer(),
          sample_table: SampleTable.t(),
          duration: non_neg_integer() | nil,
          movie_duration: non_neg_integer() | nil,
          chunk_dts_overbound: integer() | nil,
          chunk_duration: non_neg_integer() | nil
        }

  @enforce_keys [:id, :stream_format, :timescale, :sample_table]

  defstruct @enforce_keys ++
              [duration: nil, movie_duration: nil, chunk_dts_overbound: nil, chunk_duration: nil]

  @spec new(pos_integer(), struct(), non_neg_integer() | nil) :: __MODULE__.t()
  def new(id, stream_format, chunk_duration \\ nil) do
    %__MODULE__{
      id: id,
      chunk_duration: chunk_duration,
      stream_format: stream_format,
      sample_table: %SampleTable{
        sample_description: stream_format,
        timescale: get_timescale(stream_format)
      },
      timescale: get_timescale(stream_format)
    }
  end

  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{} = track) do
    use Ratio, comparision: true

    last_dts = track.sample_table.last_dts
    bound = track.chunk_dts_overbound

    last_dts != nil and bound != nil and last_dts >= bound
  end

  @spec store_sample(__MODULE__.t(), Membrane.Buffer.t()) :: __MODULE__.t()
  def store_sample(track, buffer) do
    track
    |> Map.update!(:sample_table, &SampleTable.store_sample(&1, buffer))
    |> case do
      %{chunk_dts_overbound: nil} = track ->
        %{track | chunk_dts_overbound: buffer.dts + track.chunk_duration}

      track ->
        track
    end
  end

  @spec flush_chunk(__MODULE__.t(), non_neg_integer) :: {binary, __MODULE__.t()}
  def flush_chunk(track, chunk_offset) do
    {chunk, sample_table} = SampleTable.flush_chunk(track.sample_table, chunk_offset)

    track =
      %{
        track
        | sample_table: sample_table,
          chunk_dts_overbound: track.chunk_dts_overbound + track.chunk_duration
      }

    {chunk, track}
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
          profile: profile,
          channels: channels,
          sample_rate: sample_rate
        }
      }) do
    map = %{
      aot_id: AAC.profile_to_aot_id(profile),
      channels: AAC.channels_to_channel_config_id(channels),
      frequency: sample_rate
    }

    {:mp4a, map}
  end

  def get_encoding_info(%__MODULE__{
        stream_format: %H264{
          stream_structure: {avc, <<1, profile, compatibility, level, _rest::binary>>} = structure
        }
      })
      when H264.is_avc(structure) do
    map = %{
      profile: profile,
      compatibility: compatibility,
      level: level
    }

    {avc, map}
  end

  def get_encoding_info(_unknown), do: nil

  defp get_timescale(stream_format) do
    case stream_format do
      %Membrane.Opus{} -> 48_000
      %Membrane.AAC{sample_rate: sample_rate} -> sample_rate
      %Membrane.H264{framerate: nil} -> 30 * 1024
      %Membrane.H264{framerate: {0, _denominator}} -> 30 * 1024
      %Membrane.H264{framerate: {nominator, _denominator}} -> nominator * 1024
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
