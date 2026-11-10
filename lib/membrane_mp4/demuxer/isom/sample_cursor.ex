defmodule Membrane.MP4.Demuxer.ISOM.SampleCursor do
  @moduledoc "Walks the samples of one track, as described by its `stbl` box, one at a time."

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.PackedList

  @enforce_keys [:remaining, :sample_size, :sample_sizes, :deltas, :offsets, :chunk]
  defstruct @enforce_keys

  @typedoc "Where the cursor is in each of the track's sample tables, with the entries it has not read yet."
  @type t :: %__MODULE__{
          remaining: non_neg_integer(),
          sample_size: non_neg_integer(),
          sample_sizes: PackedList.t() | nil,
          deltas: run(),
          offsets: run() | nil,
          chunk: chunk()
        }

  @typedoc "The unread entries of an stts or ctts table together with the current value and how many more samples share it."
  @type run :: %{entries: PackedList.t(), value: integer(), left: non_neg_integer()}

  @typedoc "The unread stsc groups and chunk offsets together with where the cursor is inside the current chunk."
  @type chunk :: %{
          groups: PackedList.t(),
          offsets: PackedList.t(),
          no: non_neg_integer(),
          samples_per_chunk: non_neg_integer(),
          left: non_neg_integer(),
          position: non_neg_integer()
        }

  @typedoc "One sample as the cursor hands it out, with its size and byte offset in the file and its timing."
  @type sample :: %{
          size: non_neg_integer(),
          sample_delta: non_neg_integer(),
          sample_composition_offset: integer(),
          sample_offset: non_neg_integer()
        }

  @spec new(stbl :: %{fields: Container.fields_t(), children: Container.t()}) :: t()
  def new(%{children: boxes}) do
    %__MODULE__{
      remaining: boxes[:stsz].fields.sample_count,
      sample_size: boxes[:stsz].fields.sample_size,
      sample_sizes: boxes[:stsz].fields[:entry_list],
      deltas: run(boxes[:stts].fields.entry_list),
      offsets: boxes[:ctts] && run(boxes[:ctts].fields.entry_list),
      chunk:
        chunk(boxes[:stsc].fields.entry_list, (boxes[:stco] || boxes[:co64]).fields.entry_list)
    }
  end

  @spec next(t()) :: {sample(), t()} | :end_of_stream
  def next(%{remaining: 0}) do
    :end_of_stream
  end

  def next(cursor) do
    {size, cursor} = pop_size(cursor)
    {offset, chunk} = next_in_chunk(cursor.chunk, size)
    {delta, deltas} = next_in_run(cursor.deltas, :sample_delta)
    {composition_offset, offsets} = next_in_run(cursor.offsets, :sample_composition_offset)

    sample = %{
      size: size,
      sample_delta: delta,
      sample_composition_offset: composition_offset,
      sample_offset: offset
    }

    cursor = %{
      cursor
      | remaining: cursor.remaining - 1,
        chunk: chunk,
        deltas: deltas,
        offsets: offsets
    }

    {sample, cursor}
  end

  defp pop_size(%{sample_size: 0} = cursor) do
    {%{entry_size: size}, sizes} = PackedList.pop(cursor.sample_sizes)
    {size, %{cursor | sample_sizes: sizes}}
  end

  defp pop_size(%{sample_size: size} = cursor) do
    {size, cursor}
  end

  defp chunk(groups, offsets) do
    %{groups: groups, offsets: offsets, no: 0, samples_per_chunk: 0, left: 0, position: 0}
  end

  defp next_in_chunk(%{left: 0} = chunk, size) do
    no = chunk.no + 1

    chunk =
      case PackedList.pop(chunk.groups) do
        {%{first_chunk: ^no, samples_per_chunk: samples_per_chunk}, groups} ->
          %{chunk | groups: groups, samples_per_chunk: samples_per_chunk}

        _other ->
          chunk
      end

    {%{chunk_offset: position}, offsets} = PackedList.pop(chunk.offsets)

    %{chunk | no: no, offsets: offsets, left: chunk.samples_per_chunk, position: position}
    |> next_in_chunk(size)
  end

  defp next_in_chunk(chunk, size) do
    {chunk.position, %{chunk | left: chunk.left - 1, position: chunk.position + size}}
  end

  defp run(entries) do
    %{entries: entries, value: 0, left: 0}
  end

  defp next_in_run(nil, _value_key) do
    {0, nil}
  end

  defp next_in_run(%{left: left} = run, _value_key) when left > 0 do
    {run.value, %{run | left: left - 1}}
  end

  defp next_in_run(run, value_key) do
    {entry, entries} = PackedList.pop(run.entries)
    run = %{run | entries: entries, value: Map.fetch!(entry, value_key), left: entry.sample_count}
    next_in_run(run, value_key)
  end
end
