defmodule Membrane.MP4.Muxer.CMAF.SegmentDurationRange do
  @moduledoc """
  Structure specifying the minimal and target duration for a CMAF segment.

  Each regular CMAF segment usually has to begin with a key frame. Sometimes the video stream
  can have irregularly occurring key frames which can influence the duration of a single segment.

  It may happen that the segment duration significantly exceeds the target duration as the samples
  are aggregated until reaching a key frame which allows for finalizing the current segment and starting a new one.

  ## Irregular key frames
  Let's study the following example:
  - we are streaming with an OBS on a mediocre machine
  - segment's target duration is set to 2 seconds, so we are expecting a key frame every 2 seconds
  - partial's segment target duration is set to 0.5 seconds so we want to create 4 partial 
    segments for each segment

  The broadcasting machine becomes overloaded and the OBS starts to drop the frame rate, as a result
  the key frames don't get produced regularly every 2 seconds but sometimes it may happen after 1.2 seconds
  or so and then it may get back to normal. 

  In this case we would produce 2 partial segments and a half. With a naive approach we could just try to gather
  4 partial segments and with the 5 we just aggregate samples until reaching a key frame but in this case the last segments
  could be even 1.2 seconds long (as we are expecting to get the next key frame at around 3.2 seconds).

  The idea is to have minimal and target durations. We just need to ensure that segments would have at least
  the minimal duration after which we can perform lookaheads for key frames so that we can end the partial segment
  early and start a new one. In our case we would produce 2 full partial segments and one with a duration of 0.2 seconds.
  Effectively, the third partial segment would start with a key frame.
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
