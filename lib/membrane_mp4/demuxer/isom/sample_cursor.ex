defmodule Membrane.MP4.Demuxer.ISOM.SampleCursor do
  @moduledoc "Walks the samples of one track, as described by its `stbl` box, one at a time."

  alias Membrane.MP4.Container.PackedList

  @enforce_keys [:remaining, :sizes, :deltas, :offsets, :chunk_groups, :chunk_offsets]
  defstruct @enforce_keys ++
              [
                delta_run: {0, 0},
                offset_run: {0, 0},
                chunk_no: 0,
                samples_per_chunk: 0,
                left_in_chunk: 0,
                position: 0
              ]

  @type t :: %__MODULE__{
          remaining: non_neg_integer(),
          sizes: PackedList.t() | pos_integer(),
          deltas: PackedList.t(),
          offsets: PackedList.t() | nil,
          chunk_groups: PackedList.t(),
          chunk_offsets: PackedList.t(),
          delta_run: {integer(), non_neg_integer()},
          offset_run: {integer(), non_neg_integer()},
          chunk_no: non_neg_integer(),
          samples_per_chunk: non_neg_integer(),
          left_in_chunk: non_neg_integer(),
          position: non_neg_integer()
        }

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
      sizes: sizes(boxes[:stsz].fields),
      deltas: boxes[:stts].fields.entry_list,
      offsets: boxes[:ctts] && boxes[:ctts].fields.entry_list,
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
    {delta, cursor} = run_value(cursor, :deltas, :delta_run, :sample_delta)
    {offset, cursor} = run_value(cursor, :offsets, :offset_run, :sample_composition_offset)

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

  defp sizes(%{sample_size: 0, entry_list: sizes}) do
    sizes
  end

  defp sizes(%{sample_size: size}) do
    size
  end

  defp pop_size(%{sizes: size} = cursor) when is_integer(size) do
    {size, cursor}
  end

  defp pop_size(%{sizes: sizes} = cursor) do
    {%{entry_size: size}, sizes} = PackedList.pop(sizes)
    {size, %{cursor | sizes: sizes}}
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

  defp run_value(cursor, list_key, run_key, value_key) do
    case {Map.fetch!(cursor, run_key), Map.fetch!(cursor, list_key)} do
      {{value, left}, _list} when left > 0 ->
        {value, Map.put(cursor, run_key, {value, left - 1})}

      {_run, nil} ->
        {0, cursor}

      {_run, list} ->
        {entry, list} = PackedList.pop(list)

        cursor
        |> Map.put(list_key, list)
        |> Map.put(run_key, {Map.fetch!(entry, value_key), entry.sample_count})
        |> run_value(list_key, run_key, value_key)
    end
  end
end
