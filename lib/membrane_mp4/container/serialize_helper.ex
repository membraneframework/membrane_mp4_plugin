defmodule Membrane.MP4.Container.SerializeHelper do
  @moduledoc false

  use Bunch

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema

  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @spec serialize_boxes(Container.t(), Schema.t()) ::
          {:error, Container.serialize_error_context_t()} | {:ok, binary}
  def serialize_boxes(mp4, schema) do
    with {:ok, data} <-
           Bunch.Enum.try_map(mp4, fn {box_name, box} ->
             serialize_box(box_name, box, Map.fetch(schema, box_name))
           end) do
      {:ok, IO.iodata_to_binary(data)}
    end
  end

  defp serialize_box(box_name, %{content: content}, _schema) do
    header = serialize_header(box_name, byte_size(content))
    {:ok, [header, content]}
  end

  defp serialize_box(box_name, box, {:ok, schema}) do
    with {:ok, fields} <- serialize_fields(Map.get(box, :fields, %{}), schema.fields),
         {:ok, children} <- serialize_boxes(Map.get(box, :children, %{}), schema.children) do
      header = serialize_header(box_name, byte_size(fields) + byte_size(children))
      {:ok, [header, fields, children]}
    else
      {:error, context} -> {:error, [box: box_name] ++ context}
    end
  end

  defp serialize_box(box_name, _box, :error) do
    {:error, unknown_box: box_name}
  end

  defp serialize_header(name, content_size) do
    <<@box_header_size + content_size::integer-size(@box_size_size)-unit(8),
      serialize_box_name(name)::binary>>
  end

  defp serialize_box_name(name) do
    Atom.to_string(name) |> String.pad_trailing(@box_name_size, [" "])
  end

  defp serialize_fields(term, fields) do
    with {:ok, data} <- serialize_field(term, fields) do
      data
      |> List.flatten()
      |> Enum.reduce(<<>>, &<<&2::bitstring, &1::bitstring>>)
      ~> {:ok, &1}
    end
  end

  defp serialize_field(term, subfields) when is_list(subfields) and is_map(term) do
    Bunch.Enum.try_map(subfields, fn
      {:reserved, data} ->
        {:ok, data}

      {name, type} ->
        with {:ok, term} <- Map.fetch(term, name),
             {:ok, data} <- serialize_field(term, type) do
          {:ok, data}
        else
          :error -> {:error, field: name}
          {:error, context} -> {:error, [field: name] ++ context}
        end
    end)
  end

  defp serialize_field(term, {:int, size}) when is_integer(term) do
    {:ok, <<term::signed-integer-size(size)>>}
  end

  defp serialize_field(term, {:uint, size}) when is_integer(term) do
    {:ok, <<term::integer-size(size)>>}
  end

  defp serialize_field({int, frac}, {:fp, int_size, frac_size})
       when is_integer(int) and is_integer(frac) do
    {:ok, <<int::integer-size(int_size), frac::integer-size(frac_size)>>}
  end

  defp serialize_field(term, :bin) when is_bitstring(term) do
    {:ok, term}
  end

  defp serialize_field(term, {type, size})
       when type in [:bin, :str] and is_bitstring(term) and bit_size(term) == size do
    {:ok, term}
  end

  defp serialize_field(term, :str) when is_binary(term) do
    {:ok, term <> "\0"}
  end

  defp serialize_field(term, {:list, type}) when is_list(term) do
    Bunch.Enum.try_map(term, &serialize_field(&1, type))
  end

  defp serialize_field(_term, _type), do: {:error, []}
end
