defmodule Membrane.MP4.Muxer.CMAF.TrackSamplesCache do
  @moduledoc false

  defstruct state: :collecting,
            supports_keyframes?: false,
            collected_duration: 0,
            collected: [],
            to_collect_duration: 0,
            to_collect: []

  @type state_t :: :collecting | :to_collect

  @type t :: %__MODULE__{
          state: state_t(),
          supports_keyframes?: boolean(),
          collected_duration: non_neg_integer(),
          collected: list(Membrane.Buffer.t()),
          to_collect: list(Membrane.Buffer.t())
        }

  @doc """
  Force pushes the sample into the cache ignoring any timestamps.
  """
  @spec force_push(t(), Membrane.Buffer.t()) :: t()
  def force_push(%__MODULE__{state: :collecting} = cache, sample) do
    %__MODULE__{
      cache
      | collected: [sample | cache.collected],
        collected_duration: cache.collected_duration + sample.metadata.duration
    }
  end

  @spec push(t(), Membrane.Buffer.t(), Membrane.Time.t()) :: t()
  def push(cache, sample, timestamp) do
    dts = Ratio.to_float(sample.dts)

    do_push(cache, sample, dts, timestamp)
  end

  defp do_push(%__MODULE__{state: :collecting} = cache, sample, dts, timestamp)
       when dts < timestamp do
    %__MODULE__{
      cache
      | collected: [sample | cache.collected],
        collected_duration: cache.collected_duration + sample.metadata.duration
    }
  end

  # we are handling video sample that has already exceeded the timestamp, don't collect until reaching a keyframe
  defp do_push(
         %__MODULE__{state: :collecting, supports_keyframes?: true} = cache,
         sample,
         _dts,
         _timestamp
       ) do
    if sample.metadata.mp4_payload.key_frame? do
      %__MODULE__{
        cache
        | state: :to_collect,
          collected: Enum.reverse(cache.collected),
          to_collect: [sample]
      }
    else
      %__MODULE__{
        cache
        | collected: [sample | cache.collected],
          collected_duration: cache.collected_duration + sample.metadata.duration
      }
    end
  end

  defp do_push(%__MODULE__{state: :collecting} = cache, sample, _dts, _timestamp) do
    %__MODULE__{
      cache
      | state: :to_collect,
        collected: Enum.reverse(cache.collected),
        to_collect: [sample]
    }
  end

  defp do_push(%__MODULE__{state: :to_collect} = cache, sample, _dts, _timestamp) do
    %__MODULE__{cache | to_collect: [sample | cache.to_collect]}
  end

  @doc """
  Pushes sample into the cache based on the given timestamp and sample's dts.

  If the sample has a dts lower than the desired timestamp then the sample will land in `collected` group,
  otherwise it means that the required samples are already collected and the sample will land in `to_collect` group
  and cache will become eligible for collection.
  """
  @spec push_part(t(), Membrane.Buffer.t(), Membrane.Time.t()) :: t()
  def push_part(%__MODULE__{state: :collecting} = cache, sample, timestamp) do
    dts = Ratio.to_float(sample.dts)

    if dts < timestamp do
      %__MODULE__{
        cache
        | collected_duration: cache.collected_duration + sample.metadata.duration,
          collected: [sample | cache.collected]
      }
    else
      %__MODULE__{
        cache
        | state: :to_collect,
          collected: Enum.reverse(cache.collected),
          to_collect: [sample]
      }
    end
  end

  def push_part(cache, sample, _timestamp) do
    %__MODULE__{cache | to_collect: [sample | cache.to_collect]}
  end

  @doc """
  Pushes sample into the cache by taking into consideration minimal, desired and end timestamps.

  The behaviour of when a cache becomes ready for collection is based on the incoming samples dts and whether
  the cache support keyframes and when the sample with a keyframe arrives.


  In general the this push behaviour will always try to accumulate samples until the minimal duration, no matter
  if the keyframe appears or not.
  Then the behaviour changes and cache will start looking for keyframes to eventually
  mark itself as ready to collect when encountring a keyframe while still collecting all samples until a mid timestamp.
  If no keyframe has been found then the cache starts to look for keyframes until the end timestamp but this time without
  putting samples into `collected` group but into the `to_collect`. When no keyframe gets found and the sample's dts exceeds
  the end timestamp then cache gets marked for collection with all frames until a mid timestamp.

  """
  @spec push_part(
          t(),
          Membrane.Buffer.t(),
          Membrane.Time.t(),
          Membrane.Time.t(),
          Membrane.Time.t()
        ) :: t()
  def push_part(cache, sample, min_timestamp, mid_timestamp, end_timestamp) do
    dts = Ratio.to_float(sample.dts)

    do_push_part(cache, sample, dts, min_timestamp, mid_timestamp, end_timestamp)
  end

  defp do_push_part(cache, sample, dts, min_timestamp, _mid_timestamp, _end_timestamp)
       when dts < min_timestamp do
    %__MODULE__{
      cache
      | collected_duration: cache.collected_duration + sample.metadata.duration,
        collected: [sample | cache.collected]
    }
  end

  defp do_push_part(cache, sample, dts, _min_timestamp, mid_timestamp, _end_timestamp)
       when dts < mid_timestamp do
    %__MODULE__{collected: collected, collected_duration: duration} = cache

    if cache.supports_keyframes? and sample.metadata.mp4_payload.key_frame? do
      %__MODULE__{
        cache
        | state: :to_collect,
          collected: Enum.reverse(collected),
          to_collect: [sample]
      }
    else
      %__MODULE__{
        cache
        | collected_duration: duration + sample.metadata.duration,
          collected: [sample | collected]
      }
    end
  end

  defp do_push_part(cache, sample, dts, _min_timestamp, _mid_timestamp, end_timestamp)
       when dts < end_timestamp do
    %__MODULE__{collected: collected, to_collect: to_collect, collected_duration: duration} =
      cache

    # if we have a keyframe we just return the sample from the collected duration
    if cache.supports_keyframes? and sample.metadata.mp4_payload.key_frame? do
      %__MODULE__{
        cache
        | state: :to_collect,
          collected: Enum.reverse(to_collect ++ collected),
          to_collect: [sample]
      }
    else
      # in case we already exceeded the mid timestamp we don't want to push the sample to collected (unless further we encounter a key frame)
      # NOTE: but we increase the duration
      %__MODULE__{
        cache
        | collected_duration: duration + sample.metadata.duration,
          to_collect: [sample | to_collect]
      }
    end
  end

  defp do_push_part(cache, sample, _dts, _min_timestamp, _mid_timestamp, _end_timestamp) do
    if cache.state == :to_collect do
      %__MODULE__{cache | to_collect: [sample | cache.to_collect]}
    else
      if cache.supports_keyframes? and sample.metadata.mp4_payload.key_frame? do
        collected = cache.to_collect ++ cache.collected

        %__MODULE__{
          cache
          | state: :to_collect,
            collected: Enum.reverse(collected),
            collected_duration: total_duration(cache.to_collect),
            to_collect: [sample]
        }
      else
        %__MODULE__{
          cache
          | state: :to_collect,
            collected: Enum.reverse(cache.collected),
            to_collect: [sample | cache.to_collect]
        }
      end
    end
  end

  defp total_duration(samples), do: Enum.map(samples, & &1.metadata.duration) |> Enum.sum()

  @doc """
  Forces collection until a given timestamp.

  If the cache is already in `:to_collect` state then the function works the
  same as `collect/1`.
  """
  @spec force_collect(t(), Membrane.Time.t()) :: {[Membrane.Buffer.t()], t()}
  def force_collect(%__MODULE__{state: :collecting} = cache, end_timestamp) do
    use Ratio, comparison: true

    {to_collect, collected} = Enum.split_while(cache.collected, &(&1.dts >= end_timestamp))

    result = Enum.reverse(collected)

    cache = %__MODULE__{
      cache
      | collected: to_collect,
        to_collect: [],
        collected_duration: total_duration(to_collect)
    }

    {result, cache}
  end

  def force_collect(%__MODULE__{state: :to_collect} = cache, _timestamp), do: collect(cache)

  @doc """
  Collects samples from given cache.

  Cache itself must be in ':to_collect' state to perform collection.
  """
  @spec collect(t()) :: {[Membrane.Buffer.t()], t()}
  def collect(%__MODULE__{state: :to_collect} = cache) do
    %__MODULE__{collected: collected} = cache

    cache = %__MODULE__{
      supports_keyframes?: cache.supports_keyframes?,
      collected: cache.to_collect,
      collected_duration: total_duration(cache.to_collect)
    }

    {collected, cache}
  end

  @doc """
  Drains all samples from cache.

  Similar to `collect/1` but returns all cached samples instead
  of those marked for collection.
  """
  @spec drain_samples(t()) :: {[Membrane.Buffer.t()], t()}
  def drain_samples(%__MODULE__{state: :to_collect} = cache) do
    {cache.collected ++ Enum.reverse(cache.to_collect), %__MODULE__{}}
  end

  def drain_samples(%__MODULE__{state: :collecting} = cache) do
    {Enum.reverse(cache.to_collect ++ cache.collected), %__MODULE__{}}
  end

  @doc """
  Checks if cache contians any samples.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{collected: collected, to_collect: to_collect}) do
    Enum.empty?(collected) and Enum.empty?(to_collect)
  end

  @doc """
  Returns dts of the latest sample that is eligible for collection.

  In case of ':collecting' state it is the last sample that has been put to cache.
  When in ':to_collect' state it is the last sample that will be in return from 'collect/1'.
  """
  @spec last_collected_dts(t()) :: integer()
  def last_collected_dts(%__MODULE__{
        state: :collecting,
        collected: collected,
        to_collect: to_collect
      }),
      do: latest_collected_dts(to_collect) || latest_collected_dts(collected) || -1

  def last_collected_dts(%__MODULE__{state: :to_collect, collected: collected}),
    do: latest_collected_dts(List.last(collected, []) |> List.wrap()) || -1

  defp latest_collected_dts([]), do: nil
  defp latest_collected_dts([sample | _rest]), do: Ratio.to_float(sample.dts)

  @doc """
  Returns the most recenlty pushed sample.
  """
  @spec last_sample(t()) :: Membrane.Buffer.t() | nil
  def last_sample(%__MODULE__{state: :collecting, collected: [last_sample | _rest]}),
    do: last_sample

  def last_sample(%__MODULE__{state: :to_collect, to_collect: [], collected: collected}),
    do: List.last(collected)

  def last_sample(%__MODULE__{state: :to_collect, to_collect: [last_sample | _rest]}),
    do: last_sample
end
