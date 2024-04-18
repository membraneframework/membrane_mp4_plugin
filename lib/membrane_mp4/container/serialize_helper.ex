defmodule Membrane.MP4.Container.SerializeHelper do
  @moduledoc false
  use Bunch

  import Bitwise

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema

  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @type context_t() :: %{atom() => integer()}

  @spec serialize_boxes(Container.t(), Schema.t(), context_t()) ::
          {{:error, Container.serialize_error_context_t()}, context_t()}
          | {{:ok, binary}, context_t()}
  def serialize_boxes(mp4, schema, context) do
    with {{:ok, data}, context} <-
           Bunch.Enum.try_map_reduce(mp4, context, fn {box_name, box}, context ->
             serialize_box(box_name, box, Map.fetch(schema, box_name), context)
           end) do
      {{:ok, IO.iodata_to_binary(data)}, context}
    end
  end

  defp serialize_box(box_name, %{content: content}, _schema, context) do
    header = serialize_header(box_name, byte_size(content))
    {{:ok, [header, content]}, context}
  end

  defp serialize_box(box_name, box, {:ok, schema}, context) do
    with {{:ok, fields}, context} <-
           serialize_fields(Map.get(box, :fields, %{}), schema.fields, context),
         {{:ok, children}, context} <-
           serialize_boxes(Map.get(box, :children, %{}), schema.children, context) do
      header = serialize_header(box_name, byte_size(fields) + byte_size(children))
      {{:ok, [header, fields, children]}, context}
    else
      {{:error, error_context}, context} -> {{:error, [box: box_name] ++ error_context}, context}
    end
  end

  defp serialize_box(box_name, _box, :error, context) do
    {{:error, unknown_box: box_name}, context}
  end

  defp serialize_header(name, content_size) do
    <<@box_header_size + content_size::integer-size(@box_size_size)-unit(8),
      serialize_box_name(name)::binary>>
  end

  defp serialize_box_name(name) do
    Atom.to_string(name) |> String.pad_trailing(@box_name_size, [" "])
  end

  defp serialize_fields(term, fields, context) do
    with {{:ok, data}, context} <- serialize_field(term, fields, context) do
      data
      |> List.flatten()
      |> Enum.reduce(<<>>, &<<&2::bitstring, &1::bitstring>>)
      ~> {{:ok, &1}, context}
    end
  end

  defp serialize_field(term, {type, store: context_name, when: condition}, context) do
    {flag_value, key, mask} = condition
    context_object = Map.get(context, key)

    if context_object != nil and (mask &&& context_object) == flag_value do
      serialize_field(term, {type, store: context_name}, context)
    else
      {{:ok, <<>>}, context}
    end
  end

  defp serialize_field(term, {type, store: context_name}, context) do
    context = Map.put(context, context_name, term)
    serialize_field(term, type, context)
  end

  defp serialize_field(term, {type, when: condition}, context) do
    {flag_value, key, mask} = condition
    context_object = Map.get(context, key, 0)

    if (mask &&& context_object) == flag_value do
      serialize_field(term, type, context)
    else
      {{:ok, <<>>}, context}
    end
  end

  defp serialize_field(term, subfields, context) when is_list(subfields) and is_map(term) do
    Bunch.Enum.try_map_reduce(subfields, context, fn
      {:reserved, data}, context ->
        {{:ok, data}, context}

      {name, type}, context ->
        with term <- Map.get(term, name),
             {{:ok, data}, context} <- serialize_field(term, type, context) do
          {{:ok, data}, context}
        else
          {{:error, error_context}, context} ->
            {{:error, [field: name] ++ error_context}, context}
        end
    end)
  end

  defp serialize_field(term, {:int, size}, context) when is_integer(term) do
    {{:ok, <<term::signed-integer-size(size)>>}, context}
  end

  defp serialize_field(term, {:uint, size}, context) when is_integer(term) do
    {{:ok, <<term::integer-size(size)>>}, context}
  end

  defp serialize_field({int, frac}, {:fp, int_size, frac_size}, context)
       when is_integer(int) and is_integer(frac) do
    {{:ok, <<int::integer-size(int_size), frac::integer-size(frac_size)>>}, context}
  end

  defp serialize_field(term, :bin, context) when is_bitstring(term) do
    {{:ok, term}, context}
  end

  defp serialize_field(term, {type, size}, context)
       when type in [:bin, :str] and is_bitstring(term) and bit_size(term) == size do
    {{:ok, term}, context}
  end

  defp serialize_field(term, :str, context) when is_binary(term) do
    {{:ok, term <> "\0"}, context}
  end

  defp serialize_field(term, {:list, type}, context) when is_list(term) do
    Bunch.Enum.try_map_reduce(term, context, fn term, context ->
      case serialize_field(term, type, context) do
        {{:ok, term}, context} -> {{:ok, term}, context}
        {{:error, error_context}, context} -> {{:error, error_context}, context}
      end
    end)
  end

  defp serialize_field(_term, _type, context), do: {{:error, []}, context}
end
