defmodule Membrane.MP4.Container.SerializeHelper do
  @moduledoc false

  use Bunch
  use Bitwise

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema

  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @spec serialize_boxes(Container.t(), Schema.t(), any()) ::
          {:error, Container.serialize_error_context_t()} | {:ok, binary, any()}
  def serialize_boxes(mp4, schema, storage) do
    with {{:ok, data}, storage} <-
           Bunch.Enum.try_map_reduce(mp4, storage, fn {box_name, box}, storage ->
             case serialize_box(box_name, box, Map.fetch(schema, box_name), storage) do
               {:ok, data, storage} -> {{:ok, data}, storage}
               {:error, context} -> {{:error, context}, storage}
             end
           end) do
      {:ok, IO.iodata_to_binary(data), storage}
    else
      {{:error, context}, _storage} -> {:error, context}
    end
  end

  defp serialize_box(box_name, %{content: content}, _schema, storage) do
    header = serialize_header(box_name, byte_size(content))
    {:ok, [header, content], storage}
  end

  defp serialize_box(box_name, box, {:ok, schema}, storage) do
    with {:ok, fields, storage} <-
           serialize_fields(Map.get(box, :fields, %{}), schema.fields, storage),
         {:ok, children, storage} <-
           serialize_boxes(Map.get(box, :children, %{}), schema.children, storage) do
      header = serialize_header(box_name, byte_size(fields) + byte_size(children))
      {:ok, [header, fields, children], storage}
    else
      {:error, context} -> {:error, [box: box_name] ++ context}
    end
  end

  defp serialize_box(box_name, _box, :error, _storage) do
    {:error, unknown_box: box_name}
  end

  defp serialize_header(name, content_size) do
    <<@box_header_size + content_size::integer-size(@box_size_size)-unit(8),
      serialize_box_name(name)::binary>>
  end

  defp serialize_box_name(name) do
    Atom.to_string(name) |> String.pad_trailing(@box_name_size, [" "])
  end

  defp serialize_fields(term, fields, storage) do
    with {:ok, data, storage} <- serialize_field(term, fields, storage) do
      data
      |> List.flatten()
      |> Enum.reduce(<<>>, &<<&2::bitstring, &1::bitstring>>)
      ~> {:ok, &1, storage}
    end
  end

  defp serialize_field(term, {type, store: storage_name}, storage) do
    storage = Map.put(storage, storage_name, term)
    serialize_field(term, type, storage)
  end

  defp serialize_field(term, {type, when: condition}, storage) do
    {flag, key} = condition
    storage_object = Map.get(storage, key)

    if storage_object != nil and (flag &&& storage_object) == flag do
      serialize_field(term, type, storage)
    else
      {:ok, <<>>, storage}
    end
  end

  defp serialize_field(term, subfields, storage) when is_list(subfields) and is_map(term) do
    case Bunch.Enum.try_map_reduce(subfields, storage, fn
           {:reserved, data}, storage ->
             {{:ok, data}, storage}

           {name, type}, storage ->
             with term <- Map.get(term, name),
                  {:ok, data, storage} <- serialize_field(term, type, storage) do
               {{:ok, data}, storage}
             else
               :error ->
                 {{:error, field: name}, storage}

               {:error, context} ->
                 {{:error, [field: name] ++ context}, storage}
             end
         end) do
      {{:ok, results}, storage} -> {:ok, results, storage}
      {{:error, context}, _storage} -> {:error, context}
    end
  end

  defp serialize_field(term, {:int, size}, storage) when is_integer(term) do
    {:ok, <<term::signed-integer-size(size)>>, storage}
  end

  defp serialize_field(term, {:uint, size}, storage) when is_integer(term) do
    {:ok, <<term::integer-size(size)>>, storage}
  end

  defp serialize_field({int, frac}, {:fp, int_size, frac_size}, storage)
       when is_integer(int) and is_integer(frac) do
    {:ok, <<int::integer-size(int_size), frac::integer-size(frac_size)>>, storage}
  end

  defp serialize_field(term, :bin, storage) when is_bitstring(term) do
    {:ok, term, storage}
  end

  defp serialize_field(term, {type, size}, storage)
       when type in [:bin, :str] and is_bitstring(term) and bit_size(term) == size do
    {:ok, term, storage}
  end

  defp serialize_field(term, :str, storage) when is_binary(term) do
    {:ok, term <> "\0", storage}
  end

  defp serialize_field(term, {:list, type}, storage) when is_list(term) do
    case Bunch.Enum.try_map_reduce(term, storage, fn term, storage ->
           case serialize_field(term, type, storage) do
             {:ok, term, storage} -> {{:ok, term}, storage}
             {:error, context} -> {{:error, context}, storage}
           end
         end) do
      {{:ok, results}, storage} -> {:ok, results, storage}
      {{:error, context}, _storage} -> {:error, context}
    end
  end

  defp serialize_field(_term, _type, _storage), do: {:error, []}
end
