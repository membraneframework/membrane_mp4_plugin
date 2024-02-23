defmodule Membrane.MP4.Muxer.CMAF.TrackSamplesQueue do
  @moduledoc false

  import Membrane.MP4.Helper, only: [key_frame?: 1]

  alias Membrane.MP4.Muxer.CMAF.DurationRange

  defstruct collectable?: false,
            track_with_keyframes?: false,
            collected_samples_duration: 0,
            duration_range: nil,
            target_samples: [],
            excess_samples: []

  @type t :: %__MODULE__{
          collectable?: boolean(),
          track_with_keyframes?: boolean(),
          collected_samples_duration: non_neg_integer(),
          duration_range: DurationRange.t() | nil,
          target_samples: list(Membrane.Buffer.t()),
          excess_samples: list(Membrane.Buffer.t())
        }

  @doc """
  Force pushes the sample into the queue ignoring any durations.
  """
  @spec force_push(t(), Membrane.Buffer.t()) :: t()
  def force_push(%__MODULE__{collectable?: false} = queue, sample) do
    %__MODULE__{
      queue
      | target_samples: [sample | queue.target_samples],
        collected_samples_duration: queue.collected_samples_duration + sample.metadata.duration
    }
  end

  def force_push(%__MODULE__{collectable?: true} = queue, sample) do
    %__MODULE__{
      queue
      | excess_samples: [sample | queue.excess_samples]
    }
  end

  @doc """
  Pushes sample into the queue based on the calculated duration of the track that the sample belongs to in
  a simple manner (only cares about the target duration).

  The tracks duration is calculated based on the sample's dts and its duration.
  If the calculated duration is lower than the desired duration then the sample will land in target samples group,
  otherwise it means that the required samples are already collected and the sample will land in excess samples group
  and queue will become collectable.
  """
  @spec plain_push_until_target(t(), Membrane.Buffer.t(), Membrane.Time.t()) :: t()
  def plain_push_until_target(%__MODULE__{collectable?: false} = queue, sample, base_timestamp) do
    target_duration = base_timestamp + queue.duration_range.target

    track_duration = duration_from_sample(sample)

    if track_duration <= target_duration do
      %__MODULE__{
        queue
        | collected_samples_duration: queue.collected_samples_duration + sample.metadata.duration,
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

  def plain_push_until_target(%__MODULE__{collectable?: true} = queue, sample, _base_timestamp) do
    %__MODULE__{queue | excess_samples: [sample | queue.excess_samples]}
  end

  @doc """
  Pushes sample into the queue by taking into consideration minimal, target and max track durations.

  The behaviour of when a queue becomes collectable is based on the track's duration (after taking the incoming sample into consideration)
  and whether the following sample contains a keyframe.

  In general the this push behaviour will always try to accumulate samples until the minimal duration, no matter
  if the keyframe appears or not.
  Then the behaviour changes and queue will start looking for keyframes to eventually
  mark itself as collectable when encountering a keyframe while still collecting all samples until a target duration.

  If no keyframe has been found, then the queue starts to look for keyframes until the max duration but this time without
  putting samples into target samples group but into the excess samples one.
  When no keyframe gets found and the track's duration exceeds the max duration then
  queue gets marked as collectable with all frames until a target duration time point.
  """
  @spec push_until_end(
          t(),
          Membrane.Buffer.t(),
          Membrane.Time.t()
        ) :: t()
  def push_until_end(queue, sample, base_timestamp) do
    range = queue.duration_range
    min_duration = base_timestamp + range.min
    target_duration = base_timestamp + range.target
    max_duration = base_timestamp + range.min + range.target

    duration = duration_from_sample(sample)

    do_push(queue, sample, duration, min_duration, target_duration, max_duration)
  end

  @doc """
  Similar to `push_until_end/3` but the max duration is set to infinity.
  """
  @spec push_until_target(t(), Membrane.Buffer.t(), Membrane.Time.t()) :: t()
  def push_until_target(queue, sample, base_timestamp) do
    range = queue.duration_range
    min_duration = base_timestamp + range.min
    target_duration = base_timestamp + range.target
    max_duration = :infinity

    duration = duration_from_sample(sample)

    do_push(queue, sample, duration, min_duration, target_duration, max_duration)
  end

  defp do_push(queue, sample, duration, min_duration, _target_duration, _max_duration)
       when duration <= min_duration do
    %__MODULE__{
      queue
      | collected_samples_duration: queue.collected_samples_duration + sample.metadata.duration,
        target_samples: [sample | queue.target_samples]
    }
  end

  defp do_push(queue, sample, duration, _min_duration, target_duration, _max_duration)
       when duration <= target_duration do
    %__MODULE__{
      target_samples: target_samples,
      collected_samples_duration: collected_samples_duration
    } = queue

    if queue.track_with_keyframes? and key_frame?(sample.metadata) do
      %__MODULE__{
        queue
        | collectable?: true,
          target_samples: Enum.reverse(target_samples),
          excess_samples: [sample]
      }
    else
      %__MODULE__{
        queue
        | collected_samples_duration: collected_samples_duration + sample.metadata.duration,
          target_samples: [sample | target_samples]
      }
    end
  end

  defp do_push(queue, sample, duration, _min_duration, _target_duration, max_duration)
       when duration <= max_duration do
    %__MODULE__{
      target_samples: target_samples,
      excess_samples: excess_samples,
      collected_samples_duration: collected_samples_duration
    } = queue

    if (queue.track_with_keyframes? and key_frame?(sample.metadata)) or
         not queue.track_with_keyframes? do
      %__MODULE__{
        queue
        | collectable?: true,
          target_samples: Enum.reverse(excess_samples ++ target_samples),
          excess_samples: [sample]
      }
    else
      # in case we already exceeded the target duration we don't want to push the sample to target samples group (unless further we encounter a key frame)
      # NOTE: but we increase the duration
      %__MODULE__{
        queue
        | collected_samples_duration: collected_samples_duration + sample.metadata.duration,
          excess_samples: [sample | excess_samples]
      }
    end
  end

  defp do_push(queue, sample, _duration, _min_duration, _target_duration, _max_duration) do
    if queue.collectable? do
      %__MODULE__{queue | excess_samples: [sample | queue.excess_samples]}
    else
      if queue.track_with_keyframes? and key_frame?(sample.metadata) do
        target_samples = queue.excess_samples ++ queue.target_samples

        %__MODULE__{
          queue
          | collectable?: true,
            target_samples: Enum.reverse(target_samples),
            collected_samples_duration: total_duration(target_samples),
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
  def force_collect(%__MODULE__{collectable?: false} = queue, max_duration) do
    use Numbers, overload_operators: true, comparison: true

    {excess_samples, target_samples} =
      Enum.split_while(queue.target_samples, &Ratio.gt?(&1.dts, max_duration))

    result = Enum.reverse(target_samples)

    queue = %__MODULE__{
      queue
      | target_samples: excess_samples,
        excess_samples: [],
        collected_samples_duration: total_duration(excess_samples)
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
    %__MODULE__{target_samples: target_samples, excess_samples: excess_samples} = queue

    queue = %__MODULE__{
      queue
      | collectable?: false,
        target_samples: excess_samples,
        excess_samples: [],
        collected_samples_duration: total_duration(excess_samples)
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
    {queue.target_samples ++ Enum.reverse(queue.excess_samples), reset_queue(queue)}
  end

  def drain_samples(%__MODULE__{collectable?: false} = queue) do
    {Enum.reverse(queue.excess_samples ++ queue.target_samples), reset_queue(queue)}
  end

  @doc """
  Checks if queue contians any samples.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{target_samples: target_samples, excess_samples: excess_samples}) do
    Enum.empty?(target_samples) and Enum.empty?(excess_samples)
  end

  @doc """
  Returns the end timestamp for latest sample that is eligible for collection.

  In case of collectable state it is the last sample that has been put to queue, otherwise
  it is the last sample that will be in return from 'collect/1'.
  """
  @spec collectable_end_timestamp(t()) :: integer()
  def collectable_end_timestamp(%__MODULE__{
        collectable?: false,
        target_samples: target_samples,
        excess_samples: excess_samples
      }) do
    sample = List.first(excess_samples) || List.first(target_samples)

    if sample do
      sample.dts + sample.metadata.duration
    else
      -1
    end
  end

  def collectable_end_timestamp(%__MODULE__{collectable?: true, target_samples: target_samples}) do
    sample = List.last(target_samples)

    sample.dts + sample.metadata.duration
  end

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

  @compile {:inline, duration_from_sample: 1}
  defp duration_from_sample(sample), do: Ratio.to_float(sample.dts) + sample.metadata.duration

  defp reset_queue(queue) do
    %__MODULE__{
      queue
      | collectable?: false,
        collected_samples_duration: 0,
        target_samples: [],
        excess_samples: []
    }
  end
end
