defmodule Membrane.MP4.Track do
  @moduledoc false

  # Structure representing an MP4 track.
  # Durations of a track is initialized
  # with 0 and calculated on its finalization.

  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Payload

  @type t :: %__MODULE__{
          id: integer,
          timescale: integer,
          height: :integer,
          width: :integer,
          content: %Payload.AVC1{} | %Payload.AAC{},
          buffers: Qex.t(%Buffer{}),
          sample_count: integer,
          duration: %{
            absolute: integer,
            normalized: integer
          },
          finalized?: boolean
        }

  @enforce_keys [:id, :height, :width, :timescale, :content]

  defstruct @enforce_keys ++
              [
                buffers: Qex.new(),
                sample_count: 0,
                duration: %{
                  absolute: 0,
                  normalized: 0
                },
                finalized?: false
              ]

  @spec new(%{
          content: struct,
          height: :integer,
          id: integer,
          timescale: integer,
          width: :integer
        }) :: __MODULE__.t()
  def new(config) do
    %__MODULE__{
      id: config.id,
      timescale: config.timescale,
      height: config.height,
      width: config.width,
      content: config.content
    }
  end

  @spec store_buffers(__MODULE__.t(), [%Buffer{}]) :: __MODULE__.t()
  def store_buffers(%__MODULE__{} = track, buffers) do
    track
    |> Map.update!(:buffers, &Qex.join(&1, Qex.new(buffers)))
    |> Map.update!(:sample_count, &(&1 + length(buffers)))
  end

  @spec finalize(__MODULE__.t(), integer) :: __MODULE__.t()
  def finalize(%__MODULE__{finalized?: false} = track, timescale) do
    duration = calculate_duration(track)

    Map.merge(track, %{
      duration: %{
        absolute: timescalify(duration, track.timescale),
        normalized: timescalify(duration, timescale)
      },
      finalized?: true
    })
  end

  @spec payload(__MODULE__.t()) :: binary()
  def payload(%__MODULE__{buffers: buffers}) do
    buffers
    |> Enum.map(& &1.payload)
    |> Enum.join()
  end

  defp calculate_duration(%__MODULE__{sample_count: 0}), do: 0
  defp calculate_duration(%__MODULE__{sample_count: 1}), do: 0

  defp calculate_duration(%__MODULE__{} = track) do
    use Ratio

    # fixme: workaround here, cause we don't know the duration of last sample
    first_timestamp = Qex.first!(track.buffers).metadata.timestamp
    last_timestamp = Qex.last!(track.buffers).metadata.timestamp

    avg = div(last_timestamp - first_timestamp, track.sample_count)

    avg * (track.sample_count + 1)
  end

  defp timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end
end
