defmodule Membrane.MP4.Muxer.CMAF.SegmentDurationRange do
  @moduledoc """
  Structure specifying the minimal and target duration for a CMAF segment.

  Each regular CMAF segment usually has to begin with a keyframe. Sometimes the video stream
  can have irregularly occuring keyframes which can influence the duration of a single segment.

  It may happen that the segment duration significantly exceeds the target duration as the samples
  are aggregated until reaching a keyframe which allows for finalizing the current segment and starting a new one.

  Let's study the following example:
  the encoder is set to produce keyframes every 2 seconds which is our target duration. When a system is under load
  the encoder may decide to produce a keyframe earlier than expected e.g. after 1.5s. So
  """

  @enforce_keys [:min, :target]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          min: Membrane.Time.t(),
          target: Membrane.Time.t()
        }

  @spec new(Membrane.Time.t(), Membrane.Time.t()) :: t()
  def new(min, target) when min <= target do
    %__MODULE__{min: min || target, target: target}
  end

  @spec new(Membrane.Time.t()) :: t()
  def new(target) do
    %__MODULE__{min: target, target: target}
  end

  @spec validate(t()) :: :ok | {:error, :invalid_range}
  def validate(%__MODULE__{min: min, target: target}) when min <= target, do: :ok
  def validate(_range), do: {:error, :invalid_range}
end
