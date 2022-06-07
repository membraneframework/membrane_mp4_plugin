defmodule Membrane.MP4.Container.ParseHelper do
  @moduledoc false

  use Bunch
  use Bitwise

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema

  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @spec parse_boxes(binary, Schema.t(), any(), Container.t()) ::
          {:ok, Container.t(), any()} | {:error, Container.parse_error_context_t()}
  def parse_boxes(<<>>, _schema, storage, acc) do
    {:ok, Enum.reverse(acc), storage}
  end

  def parse_boxes(data, schema, storage, acc) do
    withl header: {:ok, {name, content, data}} <- parse_box_header(data),
          do: box_schema = schema[name],
          known?: true <- box_schema && not box_schema.black_box?,
          try:
            {:ok, {fields, rest}, storage} <- parse_fields(content, box_schema.fields, storage),
          try: {:ok, children, storage} <- parse_boxes(rest, box_schema.children, storage, []) do
      box = %{fields: fields, children: children}
      parse_boxes(data, schema, storage, [{name, box} | acc])
    else
      header: error ->
        error

      known?: _ ->
        box = %{content: content}
        parse_boxes(data, schema, storage, [{name, box} | acc])

      try: {:error, context} ->
        {:error, [box: name] ++ context}
    end
  end

  defp parse_box_header(data) do
    withl header:
            <<size::integer-size(@box_size_size)-unit(8), name::binary-size(@box_name_size),
              rest::binary>> <- data,
          do: content_size = size - @box_header_size,
          size: <<content::binary-size(content_size), rest::binary>> <- rest do
      {:ok, {parse_box_name(name), content, rest}}
    else
      header: _ -> {:error, reason: :box_header, data: data}
      size: _ -> {:error, reason: {:box_size, header: size, actual: byte_size(rest)}, data: data}
    end
  end

  defp parse_box_name(name) do
    name |> String.trim_trailing(" ") |> String.to_atom()
  end

  defp parse_fields(data, [], storage) do
    {:ok, {%{}, data}, storage}
  end

  defp parse_fields(data, [{name, type} | fields], storage) do
    with {:ok, {term, rest}, storage} <- parse_field(data, {name, type}, storage),
         {:ok, {terms, rest}, storage} <- parse_fields(rest, fields, storage) do
      {:ok, {Map.put(terms, name, term), rest}, storage}
    end
  end

  defp parse_field(data, {:reserved, reserved}, storage) do
    size = bit_size(reserved)

    case data do
      <<^reserved::bitstring-size(size), rest::bitstring>> -> {:ok, {[], rest}, storage}
      data -> parse_field_error(data, :reserved, expected: reserved)
    end
  end

  defp parse_field(data, {name, {type, store: storage_name}}, storage) do
    {:ok, result, storage} = parse_field(data, {name, type}, storage)
    {value, _rest} = result
    storage = Map.put(storage, storage_name, value)
    {:ok, result, storage}
  end

  defp parse_field(data, {name, {type, when: condition}}, storage) do
    {flag, key} = condition
    storage_object = Map.get(storage, key)

    if storage_object != nil and (flag &&& storage_object) == flag do
      parse_field(data, {name, type}, storage)
    else
      {:ok, {[], data}, storage}
    end
  end

  defp parse_field(data, {name, subfields}, storage) when is_list(subfields) do
    case parse_fields(data, subfields, storage) do
      {:ok, result, storage} -> {:ok, result, storage}
      {:error, context} -> parse_field_error(data, name, context)
    end
  end

  defp parse_field(data, {name, {:int, size}}, storage) do
    case data do
      <<int::signed-integer-size(size), rest::bitstring>> -> {:ok, {int, rest}, storage}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:uint, size}}, storage) do
    case data do
      <<uint::integer-size(size), rest::bitstring>> -> {:ok, {uint, rest}, storage}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:fp, int_size, frac_size}}, storage) do
    case data do
      <<int::integer-size(int_size), frac::integer-size(frac_size), rest::bitstring>> ->
        {:ok, {{int, frac}, rest}, storage}

      _unknown_format ->
        parse_field_error(data, name)
    end
  end

  defp parse_field(data, {_name, :bin}, storage) do
    {:ok, {data, <<>>}, storage}
  end

  defp parse_field(data, {name, {type, size}}, storage) when type in [:bin, :str] do
    case data do
      <<bin::bitstring-size(size), rest::bitstring>> -> {:ok, {bin, rest}, storage}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, :str}, storage) do
    case String.split(data, "\0", parts: 2) do
      [str, rest] -> {:ok, {str, rest}, storage}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(<<>>, {_name, {:list, _type}}, storage) do
    {:ok, {[], <<>>}, storage}
  end

  defp parse_field(data, {name, {:list, type}} = field, storage) do
    with {:ok, {term, rest}, storage} <- parse_field(data, {name, type}, storage),
         {:ok, {terms, rest}, storage} <- parse_field(rest, field, storage) do
      {:ok, {[term | terms], rest}, storage}
    end
  end

  defp parse_field(data, {name, _type}, _storage), do: parse_field_error(data, name)

  defp parse_field_error(data, name, context \\ [])

  defp parse_field_error(data, name, []) do
    {:error, field: name, data: data}
  end

  defp parse_field_error(_data, name, context) do
    {:error, [field: name] ++ context}
  end
end
