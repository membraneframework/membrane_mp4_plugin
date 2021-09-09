defmodule Membrane.MP4.Muxer.Track do
  @moduledoc false

  # Structure representing an MP4 track.

  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Payload.AVC1

  @type t :: %__MODULE__{
          id: integer,
          metadata: %{
            timescale: integer,
            height: integer,
            width: integer,
            content: struct
          },
          buffer: %{
            samples: Qex.t(binary),
            length: integer
          },
          sample_sizes: Qex.t(integer),
          key_frames: Qex.t(integer),
          chunk_offsets: Qex.t(integer),
          chunks_flushed: integer,
          sample_count: integer,
          first_timestamp: integer,
          last_timestamp: integer,
          duration: integer,
          common_duration: integer,
          samples_per_chunk: integer,
          samples_in_last_chunk: integer
        }

  @enforce_keys [:id, :metadata, :samples_per_chunk]

  defstruct @enforce_keys ++
              [
                buffer: %{
                  samples: Qex.new(),
                  length: 0
                },
                sample_sizes: Qex.new(),
                key_frames: Qex.new(),
                chunk_offsets: Qex.new(),
                sample_count: 0,
                duration: 0,
                common_duration: 0,
                chunks_flushed: 0,
                samples_in_last_chunk: 0,
                first_timestamp: nil,
                last_timestamp: nil
              ]

  @spec new(%{
          id: integer,
          samples_per_chunk: integer,
          metadata: %{
            content: struct,
            height: integer,
            timescale: integer,
            width: integer
          }
        }) :: __MODULE__.t()
  def new(config) do
    %__MODULE__{
      id: config.id,
      samples_per_chunk: config.samples_per_chunk,
      metadata: config.metadata
    }
  end

  @spec store_samples(__MODULE__.t(), [%Buffer{}]) :: __MODULE__.t()
  def store_samples(track, buffers) do
    track
    |> maybe_store_keyframes(buffers)
    |> do_store_samples(buffers)
    |> store_timestamps(buffers)
  end

  @spec try_flush_chunk(__MODULE__.t(), integer) :: {:not_ready | binary, __MODULE__.t()}
  def try_flush_chunk(%__MODULE__{} = track, chunk_offset) do
    if track.buffer.length < track.samples_per_chunk do
      {:not_ready, track}
    else
      do_flush_chunk(track, track.samples_per_chunk, chunk_offset)
    end
  end

  def finalize(%__MODULE__{} = track, chunk_offset, common_timescale) do
    track
    |> update_duration(common_timescale)
    |> do_flush_chunk(track.buffer.length, chunk_offset)
  end

  defp do_store_samples(%__MODULE__{} = track, buffers) do
    payloads = Enum.map(buffers, & &1.payload)

    Map.update!(
      track,
      :buffer,
      &%{
        samples: Qex.join(&1.samples, Qex.new(payloads)),
        length: &1.length + length(payloads)
      }
    )
  end

  defp do_flush_chunk(track, 0, _chunk_offset), do: {<<>>, track}

  defp do_flush_chunk(%__MODULE__{} = track, size, chunk_offset) do
    {to_keep, to_flush} = Qex.split(track.buffer.samples, track.buffer.length - size)

    sample_sizes = Enum.map(to_flush, &byte_size/1)
    chunk = Enum.join(to_flush)

    track =
      track
      |> Map.put(:samples_in_last_chunk, size)
      |> Map.update!(:sample_count, &(&1 + size))
      |> Map.update!(:chunks_flushed, &(&1 + 1))
      |> Map.update!(:sample_sizes, &Qex.join(&1, Qex.new(sample_sizes)))
      |> Map.update!(:chunk_offsets, &Qex.push(&1, chunk_offset))
      |> Map.update!(
        :buffer,
        &%{
          samples: to_keep,
          length: &1.length - size
        }
      )

    {chunk, track}
  end

  @spec update_duration(__MODULE__.t(), integer) :: __MODULE__.t()
  def update_duration(%__MODULE__{} = track, common_timescale) do
    duration = calculate_duration(track)

    Map.merge(track, %{
      duration: timescalify(duration, track.metadata.timescale),
      common_duration: timescalify(duration, common_timescale)
    })
  end

  defp maybe_store_keyframes(%__MODULE__{metadata: %{content: %AVC1{}}} = track, buffers) do
    current_sample = track.sample_count + track.buffer.length + 1
    last_sample = current_sample + length(buffers)

    numbered_buffers = Enum.zip(current_sample..last_sample, buffers)

    Enum.reduce(numbered_buffers, track, &store_if_keyframe/2)
  end

  defp maybe_store_keyframes(track, _buffers), do: track

  defp store_if_keyframe({number, %Buffer{metadata: %{h264: %{key_frame?: true}}}}, track) do
    Map.update!(track, :key_frames, &Qex.push(&1, number))
  end

  defp store_if_keyframe(_numbered_buffer, track), do: track

  defp store_timestamps(%{first_timestamp: nil} = track, buffers) do
    track
    |> Map.put(:first_timestamp, hd(buffers).metadata.timestamp)
    |> Map.put(:last_timestamp, List.last(buffers).metadata.timestamp)
  end

  defp store_timestamps(track, buffers) do
    %{track | last_timestamp: List.last(buffers).metadata.timestamp}
  end

  defp calculate_duration(%{sample_count: 0}), do: 0
  defp calculate_duration(%{sample_count: 1}), do: 0

  defp calculate_duration(track) do
    use Ratio

    track.last_timestamp - track.first_timestamp
  end

  defp timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end
end
