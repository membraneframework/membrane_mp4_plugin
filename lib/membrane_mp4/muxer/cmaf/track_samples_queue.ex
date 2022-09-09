defmodule Membrane.MP4.Muxer.CMAF.TrackSamplesQueue do
  @moduledoc false

  defstruct collectable?: false,
            track_with_keyframes?: false,
            collected_duration: 0,
            target_samples: [],
            to_collect_duration: 0,
            excess_samples: []

  @type state_t :: :collecting | :to_collect

  @type t :: %__MODULE__{
          collectable?: boolean(),
          track_with_keyframes?: boolean(),
          collected_duration: non_neg_integer(),
          target_samples: list(Membrane.Buffer.t()),
          excess_samples: list(Membrane.Buffer.t())
        }

  @doc """
  Force pushes the sample into the queue ignoring any timestamps.
  """
  @spec force_push(t(), Membrane.Buffer.t()) :: t()
  def force_push(%__MODULE__{collectable?: false} = queue, sample) do
    %__MODULE__{
      queue
      | target_samples: [sample | queue.target_samples],
        collected_duration: queue.collected_duration + sample.metadata.duration
    }
  end

  @doc """
  Pushes sample into the queue based on the given timestamp and sample's dts.

  If the sample has a dts lower than the desired timestamp then the sample will land in target samples group,
  otherwise it means that the required samples are already collected and the sample will land in excess samples group
  and queue will become collectable.
  """
  @spec push(t(), Membrane.Buffer.t(), Membrane.Time.t()) :: t()
  def push(%__MODULE__{collectable?: false} = queue, sample, timestamp) do
    dts = Ratio.to_float(sample.dts)

    if dts < timestamp do
      %__MODULE__{
        queue
        | collected_duration: queue.collected_duration + sample.metadata.duration,
          target_samples: [sample | queue.target_samples]
      }
    else
      %__MODULE__{
        queue
        | collectable?: true,
          target_samples: Enum.reverse(queue.target_samples),
          excess_samples: [sample]
      }
    end
  end

  def push(%__MODULE__{collectable?: true} = queue, sample, _timestamp) do
    %__MODULE__{queue | excess_samples: [sample | queue.excess_samples]}
  end

  @doc """
  Pushes sample into the queue by taking into consideration minimal, desired and end timestamps.

  The behaviour of when a queue collectable is based on the incoming samples dts and whether
  the queue's track contains keyframes and when the sample with a keyframe arrives.

  In general the this push behaviour will always try to accumulate samples until the minimal duration, no matter
  if the keyframe appears or not.
  Then the behaviour changes and queue will start looking for keyframes to eventually
  mark itself as collectable when encountring a keyframe while still collecting all samples until a mid timestamp.
  If no keyframe has been found then the queue starts to look for keyframes until the end timestamp but this time without
  putting samples into target samples group but into the excess samples one. When no keyframe gets found and the sample's dts exceeds
  the end timestamp then queue gets marked as collectable with all frames until a mid timestamp.

  """
  @spec push(
          t(),
          Membrane.Buffer.t(),
          Membrane.Time.t(),
          Membrane.Time.t(),
          Membrane.Time.t() | :infinity
        ) :: t()
  def push(queue, sample, min_timestamp, mid_timestamp, end_timestamp \\ :infinity) do
    dts = Ratio.to_float(sample.dts)

    do_push(queue, sample, dts, min_timestamp, mid_timestamp, end_timestamp)
  end

  defp do_push(queue, sample, dts, min_timestamp, _mid_timestamp, _end_timestamp)
       when dts < min_timestamp do
    %__MODULE__{
      queue
      | collected_duration: queue.collected_duration + sample.metadata.duration,
        target_samples: [sample | queue.target_samples]
    }
  end

  defp do_push(queue, sample, dts, _min_timestamp, mid_timestamp, _end_timestamp)
       when dts < mid_timestamp do
    %__MODULE__{target_samples: target_samples, collected_duration: duration} = queue

    if queue.track_with_keyframes? and sample.metadata.mp4_payload.key_frame? do
      %__MODULE__{
        queue
        | collectable?: true,
          target_samples: Enum.reverse(target_samples),
          excess_samples: [sample]
      }
    else
      %__MODULE__{
        queue
        | collected_duration: duration + sample.metadata.duration,
          target_samples: [sample | target_samples]
      }
    end
  end

  defp do_push(queue, sample, dts, _min_timestamp, _mid_timestamp, end_timestamp)
       when dts < end_timestamp do
    %__MODULE__{
      target_samples: target_samples,
      excess_samples: excess_samples,
      collected_duration: duration
    } = queue

    if (queue.track_with_keyframes? and sample.metadata.mp4_payload.key_frame?) or
         not queue.track_with_keyframes? do
      %__MODULE__{
        queue
        | collectable?: true,
          target_samples: Enum.reverse(excess_samples ++ target_samples),
          excess_samples: [sample]
      }
    else
      # in case we already exceeded the mid timestamp we don't want to push the sample to target samples group (unless further we encounter a key frame)
      # NOTE: but we increase the duration
      %__MODULE__{
        queue
        | collected_duration: duration + sample.metadata.duration,
          excess_samples: [sample | excess_samples]
      }
    end
  end

  defp do_push(queue, sample, _dts, _min_timestamp, _mid_timestamp, _end_timestamp) do
    if queue.collectable? do
      %__MODULE__{queue | excess_samples: [sample | queue.excess_samples]}
    else
      if queue.track_with_keyframes? and sample.metadata.mp4_payload.key_frame? do
        target_samples = queue.excess_samples ++ queue.target_samples

        %__MODULE__{
          queue
          | collectable?: true,
            target_samples: Enum.reverse(target_samples),
            collected_duration: total_duration(target_samples),
            excess_samples: [sample]
        }
      else
        %__MODULE__{
          queue
          | collectable?: true,
            target_samples: Enum.reverse(queue.target_samples),
            excess_samples: [sample | queue.excess_samples]
        }
      end
    end
  end

  defp total_duration(samples), do: Enum.map(samples, & &1.metadata.duration) |> Enum.sum()

  @doc """
  Forces collection until a given timestamp.

  If the queue is already collectable then the function works the
  same as `collect/1`.
  """
  @spec force_collect(t(), Membrane.Time.t()) :: {[Membrane.Buffer.t()], t()}
  def force_collect(%__MODULE__{collectable?: false} = queue, end_timestamp) do
    use Ratio, comparison: true

    {excess_samples, target_samples} =
      Enum.split_while(queue.target_samples, &(&1.dts >= end_timestamp))

    result = Enum.reverse(target_samples)

    queue = %__MODULE__{
      queue
      | target_samples: excess_samples,
        excess_samples: [],
        collected_duration: total_duration(excess_samples)
    }

    {result, queue}
  end

  def force_collect(%__MODULE__{collectable?: true} = queue, _timestamp), do: collect(queue)

  @doc """
  Collects samples from the queue.

  The queue must be marked as collectable.

  """
  @spec collect(t()) :: {[Membrane.Buffer.t()], t()}
  def collect(%__MODULE__{collectable?: true} = queue) do
    %__MODULE__{target_samples: target_samples} = queue

    queue = %__MODULE__{
      track_with_keyframes?: queue.track_with_keyframes?,
      target_samples: queue.excess_samples,
      collected_duration: total_duration(queue.excess_samples)
    }

    {target_samples, queue}
  end

  @doc """
  Drains all samples from queue.

  Similar to `collect/1` but returns all queued samples instead
  of those from target samples group.
  """
  @spec drain_samples(t()) :: {[Membrane.Buffer.t()], t()}
  def drain_samples(%__MODULE__{collectable?: true} = queue) do
    {queue.target_samples ++ Enum.reverse(queue.excess_samples), %__MODULE__{}}
  end

  def drain_samples(%__MODULE__{collectable?: false} = queue) do
    {Enum.reverse(queue.excess_samples ++ queue.target_samples), %__MODULE__{}}
  end

  @doc """
  Checks if queue contians any samples.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{target_samples: target_samples, excess_samples: excess_samples}) do
    Enum.empty?(target_samples) and Enum.empty?(excess_samples)
  end

  @doc """
  Returns dts of the latest sample that is eligible for collection.

  In case of collectable state it is the last sample that has been put to queue, otherwise
  it is the last sample that will be in return from 'collect/1'.
  """
  @spec last_collected_dts(t()) :: integer()
  def last_collected_dts(%__MODULE__{
        collectable?: false,
        target_samples: target_samples,
        excess_samples: excess_samples
      }),
      do: latest_collected_dts(excess_samples) || latest_collected_dts(target_samples) || -1

  def last_collected_dts(%__MODULE__{collectable?: true, target_samples: target_samples}),
    do: latest_collected_dts(List.last(target_samples, []) |> List.wrap()) || -1

  defp latest_collected_dts([]), do: nil
  defp latest_collected_dts([sample | _rest]), do: Ratio.to_float(sample.dts)

  @doc """
  Returns the most recenlty pushed sample.
  """
  @spec last_sample(t()) :: Membrane.Buffer.t() | nil
  def last_sample(%__MODULE__{collectable?: false, target_samples: [last_sample | _rest]}),
    do: last_sample

  def last_sample(%__MODULE__{
        collectable?: true,
        excess_samples: [],
        target_samples: target_samples
      }),
      do: List.last(target_samples)

  def last_sample(%__MODULE__{collectable?: true, excess_samples: [last_sample | _rest]}),
    do: last_sample
end
