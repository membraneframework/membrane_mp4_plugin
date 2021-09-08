defmodule Membrane.MP4.Common.Track do
  @moduledoc false

  # Structure representing an MP4 track.
  # Durations of a track is initialized
  # with 0 and calculated on update_duration/2

  alias Membrane.{Buffer, Time}

  @type kind :: :mp4 | :cmaf

  @type t :: %__MODULE__{
          id: integer,
          timescale: integer,
          height: integer,
          width: integer,
          content: struct,
          buffers: Qex.t(%Buffer{}),
          sample_count: integer,
          duration: integer,
          common_duration: integer,
          kind: kind
        }

  @enforce_keys [:id, :height, :width, :timescale, :content, :kind]

  defstruct @enforce_keys ++
              [
                buffers: Qex.new(),
                sample_count: 0,
                duration: 0,
                common_duration: 0
              ]

  @spec new(%{
          content: struct,
          height: integer,
          id: integer,
          timescale: integer,
          width: integer,
          kind: kind
        }) :: __MODULE__.t()
  def new(config) do
    %__MODULE__{
      id: config.id,
      timescale: config.timescale,
      height: config.height,
      width: config.width,
      content: config.content,
      kind: config.kind
    }
  end

  @spec store_buffers(__MODULE__.t(), [%Buffer{}]) :: __MODULE__.t()
  def store_buffers(%__MODULE__{kind: :mp4} = track, buffers) do
    track
    |> Map.update!(:buffers, &Qex.join(&1, Qex.new(buffers)))
    |> Map.update!(:sample_count, &(&1 + length(buffers)))
  end

  @spec update_duration(__MODULE__.t(), integer) :: __MODULE__.t()
  def update_duration(%__MODULE__{kind: :mp4} = track, common_timescale) do
    duration = calculate_duration(track)

    Map.merge(track, %{
      duration: timescalify(duration, track.timescale),
      common_duration: timescalify(duration, common_timescale)
    })
  end

  @spec get_payload(__MODULE__.t()) :: binary()
  def get_payload(%__MODULE__{kind: :mp4, buffers: buffers}) do
    buffers
    |> Enum.map(& &1.payload)
    |> Enum.join()
  end

  defp calculate_duration(%{sample_count: 0}), do: 0
  defp calculate_duration(%{sample_count: 1}), do: 0

  defp calculate_duration(%{buffers: buffers, sample_count: sample_count}) do
    use Ratio

    # workaround here as we don't know the duration of last sample
    first_timestamp = Qex.first!(buffers).metadata.timestamp
    last_timestamp = Qex.last!(buffers).metadata.timestamp

    avg = div(last_timestamp - first_timestamp, sample_count)

    avg * (sample_count + 1)
  end

  defp timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end
end
