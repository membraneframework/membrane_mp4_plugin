defmodule Membrane.MP4.Demuxer.ISOM.SampleCursor do
  @moduledoc "Walks the samples of one track, as described by its `stbl` box, one at a time."

  alias Membrane.MP4.Container.PackedList

  @enforce_keys [
    :remaining,
    :sample_size,
    :sample_sizes,
    :deltas,
    :offsets,
    :chunk_groups,
    :chunk_offsets
  ]
  defstruct @enforce_keys ++
              [
                chunk_no: 0,
                samples_per_chunk: 0,
                left_in_chunk: 0,
                position: 0
              ]

  @type t :: %__MODULE__{
          remaining: non_neg_integer(),
          sample_size: non_neg_integer(),
          sample_sizes: PackedList.t() | nil,
          deltas: run(),
          offsets: run() | nil,
          chunk_groups: PackedList.t(),
          chunk_offsets: PackedList.t(),
          chunk_no: non_neg_integer(),
          samples_per_chunk: non_neg_integer(),
          left_in_chunk: non_neg_integer(),
          position: non_neg_integer()
        }

  @typedoc "A run-length encoded table and the entry in progress: its value and how many samples still take it."
  @type run :: %{entries: PackedList.t(), value: integer(), left: non_neg_integer()}

  @type sample :: %{
          size: non_neg_integer(),
          sample_delta: non_neg_integer(),
          sample_composition_offset: integer(),
          sample_offset: non_neg_integer()
        }

  @spec new(stbl :: %{children: keyword()}) :: t()
  def new(%{children: boxes}) do
    %__MODULE__{
      remaining: boxes[:stsz].fields.sample_count,
      sample_size: boxes[:stsz].fields.sample_size,
      sample_sizes: boxes[:stsz].fields[:entry_list],
      deltas: run(boxes[:stts].fields.entry_list),
      offsets: boxes[:ctts] && run(boxes[:ctts].fields.entry_list),
      chunk_groups: boxes[:stsc].fields.entry_list,
      chunk_offsets: (boxes[:stco] || boxes[:co64]).fields.entry_list
    }
  end

  @spec next(t()) :: {sample(), t()} | :end_of_stream
  def next(%{remaining: 0}) do
    :end_of_stream
  end

  def next(cursor) do
    {size, cursor} = pop_size(cursor)
    cursor = enter_chunk(cursor)
    {delta, deltas} = next_in_run(cursor.deltas, :sample_delta)
    {offset, offsets} = next_in_run(cursor.offsets, :sample_composition_offset)
    cursor = %{cursor | deltas: deltas, offsets: offsets}

    sample = %{
      size: size,
      sample_delta: delta,
      sample_composition_offset: offset,
      sample_offset: cursor.position
    }

    {sample,
     %{
       cursor
       | remaining: cursor.remaining - 1,
         left_in_chunk: cursor.left_in_chunk - 1,
         position: cursor.position + size
     }}
  end

  defp pop_size(%{sample_size: 0} = cursor) do
    {%{entry_size: size}, sizes} = PackedList.pop(cursor.sample_sizes)
    {size, %{cursor | sample_sizes: sizes}}
  end

  defp pop_size(%{sample_size: size} = cursor) do
    {size, cursor}
  end

  defp enter_chunk(%{left_in_chunk: 0} = cursor) do
    chunk_no = cursor.chunk_no + 1

    cursor =
      case PackedList.pop(cursor.chunk_groups) do
        {%{first_chunk: ^chunk_no, samples_per_chunk: samples_per_chunk}, chunk_groups} ->
          %{cursor | chunk_groups: chunk_groups, samples_per_chunk: samples_per_chunk}

        _other ->
          cursor
      end

    {%{chunk_offset: position}, chunk_offsets} = PackedList.pop(cursor.chunk_offsets)

    %{
      cursor
      | chunk_no: chunk_no,
        chunk_offsets: chunk_offsets,
        left_in_chunk: cursor.samples_per_chunk,
        position: position
    }
    |> enter_chunk()
  end

  defp enter_chunk(cursor) do
    cursor
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
