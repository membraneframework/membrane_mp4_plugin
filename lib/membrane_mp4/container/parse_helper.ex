defmodule Membrane.MP4.Container.ParseHelper do
  @moduledoc false
  use Bunch

  import Bitwise

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.{Header, Schema}

  @type context_t() :: %{atom() => integer()}

  @spec parse_boxes(binary, Schema.t(), context_t(), Container.t()) ::
          {:ok, Container.t(), binary(), context_t()}
          | {:error, Container.parse_error_context_t()}
  def parse_boxes(<<>>, _schema, context, acc) do
    {:ok, Enum.reverse(acc), <<>>, context}
  end

  def parse_boxes(data, schema, context, acc) do
    withl header_content:
            {:ok, %{name: name, content_size: content_size, header_size: header_size}, rest} <-
              Header.parse(data),
          header_content: <<content::binary-size(content_size), data::binary>> <- rest,
          do: box_schema = schema[name],
          known?: true <- box_schema && not box_schema.black_box?,
          try:
            {:ok, {fields, rest}, context} <- parse_fields(content, box_schema.fields, context),
          try:
            {:ok, children, rest, context} <- parse_boxes(rest, box_schema.children, context, []),
          leftover: <<>> <- rest do
      box = %{fields: fields, children: children, size: content_size, header_size: header_size}
      parse_boxes(data, schema, context, [{name, box} | acc])
    else
      header_content: _error ->
        # more data needed
        {:ok, Enum.reverse(acc), data, context}

      known?: _ ->
        box = %{content: content, size: content_size, header_size: header_size}
        parse_boxes(data, schema, context, [{name, box} | acc])

      leftover: leftover ->
        {:error, [box: name, reason: {:non_empty_leftover, leftover}]}

      try: {:error, context} ->
        {:error, [box: name] ++ context}
    end
  end

  defp parse_fields(data, fields, context) do
    do_parse_fields(data, fields, context, %{})
  end

  defp do_parse_fields(data, [], context, acc) do
    {:ok, {acc, data}, context}
  end

  defp do_parse_fields(data, [{name, type} | fields], context, acc) do
    case parse_field(data, {name, type}, context) do
      {:ok, {term, rest}, context} ->
        acc = Map.put(acc, name, term)
        do_parse_fields(rest, fields, context, acc)

      {:ok, :ignore, context} ->
        do_parse_fields(data, fields, context, acc)

      {:error, context} ->
        {:error, context}
    end
  end

  defp parse_field(data, {:reserved, reserved}, context) do
    size = bit_size(reserved)

    case data do
      <<^reserved::bitstring-size(size), rest::bitstring>> -> {:ok, {[], rest}, context}
      data -> parse_field_error(data, :reserved, expected: reserved)
    end
  end

  defp parse_field(data, {name, {type, store: context_name, when: when_clause}}, context) do
    if handle_when(when_clause, context) do
      parse_field(data, {name, {type, store: context_name}}, context)
    else
      {:ok, :ignore, context}
    end
  end

  defp parse_field(data, {name, {type, store: context_name}}, context) do
    {:ok, result, context} = parse_field(data, {name, type}, context)
    {value, _rest} = result
    context = Map.put(context, context_name, value)
    {:ok, result, context}
  end

  defp parse_field(data, {name, {type, when: when_clause}}, context) do
    if handle_when(when_clause, context) do
      parse_field(data, {name, type}, context)
    else
      {:ok, :ignore, context}
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
      <<int::signed-integer-size(size), rest::bitstring>> ->
        {:ok, {int, rest}, context}

      _unknown_format ->
        parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:uint, size}}, context) do
    case data do
      <<uint::integer-size(size), rest::bitstring>> ->
        {:ok, {uint, rest}, context}

      _unknown_format ->
        parse_field_error(data, name)
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

  defp parse_field(data, {_name, :str}, context) do
    case String.split(data, "\0", parts: 2) do
      [str, rest] ->
        {:ok, {str, rest}, context}

      [str] ->
        {:ok, {str, <<>>}, context}
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

  defp handle_when({key, condition}, context) do
    with {:ok, value} <- Map.fetch(context, key) do
      case condition do
        [value: cond_value] -> value == cond_value
        [mask: mask] -> (mask &&& value) == mask
      end
    else
      :error ->
        raise "MP4 schema field #{key} not found in context"
    end
  end
end
