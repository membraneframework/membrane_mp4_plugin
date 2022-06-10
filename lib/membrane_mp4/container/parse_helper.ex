defmodule Membrane.MP4.Container.ParseHelper do
  @moduledoc false

  use Bunch
  use Bitwise

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema

  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @type context_t() :: %{atom() => integer()}

  @spec parse_boxes(binary, Schema.t(), context_t(), Container.t()) ::
          {:ok, Container.t(), context_t()} | {:error, Container.parse_error_context_t()}
  def parse_boxes(<<>>, _schema, context, acc) do
    {:ok, Enum.reverse(acc), context}
  end

  def parse_boxes(data, schema, context, acc) do
    withl header: {:ok, {name, content, data}} <- parse_box_header(data),
          do: box_schema = schema[name],
          known?: true <- box_schema && not box_schema.black_box?,
          try:
            {:ok, {fields, rest}, context} <- parse_fields(content, box_schema.fields, context),
          try: {:ok, children, context} <- parse_boxes(rest, box_schema.children, context, []) do
      box = %{fields: fields, children: children}
      parse_boxes(data, schema, context, [{name, box} | acc])
    else
      header: error ->
        error

      known?: _ ->
        box = %{content: content}
        parse_boxes(data, schema, context, [{name, box} | acc])

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

  defp parse_fields(data, [], context) do
    {:ok, {%{}, data}, context}
  end

  defp parse_fields(data, [{name, type} | fields], context) do
    with {:ok, {term, rest}, context} <- parse_field(data, {name, type}, context),
         {:ok, {terms, rest}, context} <- parse_fields(rest, fields, context) do
      {:ok, {Map.put(terms, name, term), rest}, context}
    end
  end

  defp parse_field(data, {:reserved, reserved}, context) do
    size = bit_size(reserved)

    case data do
      <<^reserved::bitstring-size(size), rest::bitstring>> -> {:ok, {[], rest}, context}
      data -> parse_field_error(data, :reserved, expected: reserved)
    end
  end

  defp parse_field(data, {name, {type, store: context_name, when: condition}}, context) do
    {flag, key} = condition
    context_object = Map.get(context, key, 0)

    if (flag &&& context_object) == flag do
      parse_field(data, {name, {type, store: context_name}}, context)
    else
      {:ok, {[], data}, context}
    end
  end

  defp parse_field(data, {name, {type, store: context_name}}, context) do
    {:ok, result, context} = parse_field(data, {name, type}, context)
    {value, _rest} = result
    context = Map.put(context, context_name, value)
    {:ok, result, context}
  end

  defp parse_field(data, {name, {type, when: condition}}, context) do
    {flag, key} = condition
    context_object = Map.get(context, key, 0)

    if (flag &&& context_object) == flag do
      parse_field(data, {name, type}, context)
    else
      {:ok, {[], data}, context}
    end
  end

  defp parse_field(data, {name, subfields}, context) when is_list(subfields) do
    case parse_fields(data, subfields, context) do
      {:ok, result, context} -> {:ok, result, context}
      {:error, context} -> parse_field_error(data, name, context)
    end
  end

  defp parse_field(data, {name, {:int, size}}, context) do
    case data do
      <<int::signed-integer-size(size), rest::bitstring>> -> {:ok, {int, rest}, context}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:uint, size}}, context) do
    case data do
      <<uint::integer-size(size), rest::bitstring>> -> {:ok, {uint, rest}, context}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:fp, int_size, frac_size}}, context) do
    case data do
      <<int::integer-size(int_size), frac::integer-size(frac_size), rest::bitstring>> ->
        {:ok, {{int, frac}, rest}, context}

      _unknown_format ->
        parse_field_error(data, name)
    end
  end

  defp parse_field(data, {_name, :bin}, context) do
    {:ok, {data, <<>>}, context}
  end

  defp parse_field(data, {name, {type, size}}, context) when type in [:bin, :str] do
    case data do
      <<bin::bitstring-size(size), rest::bitstring>> -> {:ok, {bin, rest}, context}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, :str}, context) do
    case String.split(data, "\0", parts: 2) do
      [str, rest] -> {:ok, {str, rest}, context}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(<<>>, {_name, {:list, _type}}, context) do
    {:ok, {[], <<>>}, context}
  end

  defp parse_field(data, {name, {:list, type}} = field, context) do
    with {:ok, {term, rest}, context} <- parse_field(data, {name, type}, context),
         {:ok, {terms, rest}, context} <- parse_field(rest, field, context) do
      {:ok, {[term | terms], rest}, context}
    end
  end

  defp parse_field(data, {name, _type}, _context), do: parse_field_error(data, name)

  defp parse_field_error(data, name, context \\ [])

  defp parse_field_error(data, name, []) do
    {:error, field: name, data: data}
  end

  defp parse_field_error(_data, name, context) do
    {:error, [field: name] ++ context}
  end
end
