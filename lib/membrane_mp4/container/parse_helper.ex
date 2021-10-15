defmodule Membrane.MP4.Container.ParseHelper do
  @moduledoc false

  use Bunch

  alias Membrane.MP4.Container
  alias Membrane.MP4.Container.Schema

  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @spec parse_boxes(binary, Schema.t(), Container.t()) ::
          {:ok | :error, Container.parse_error_context_t()}
  def parse_boxes(<<>>, _schema, acc) do
    {:ok, Enum.reverse(acc)}
  end

  def parse_boxes(data, schema, acc) do
    withl header: {:ok, {name, content, data}} <- parse_box_header(data),
          do: box_schema = schema[name],
          known?: true <- box_schema && not box_schema.black_box?,
          try: {:ok, {fields, rest}} <- parse_fields(content, box_schema.fields),
          try: {:ok, children} <- parse_boxes(rest, box_schema.children, []) do
      box = %{fields: fields, children: children}
      parse_boxes(data, schema, [{name, box} | acc])
    else
      header: error ->
        error

      known?: _ ->
        box = %{content: content}
        parse_boxes(data, schema, [{name, box} | acc])

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

  defp parse_fields(data, []) do
    {:ok, {%{}, data}}
  end

  defp parse_fields(data, [{name, type} | fields]) do
    with {:ok, {term, rest}} <- parse_field(data, {name, type}),
         {:ok, {terms, rest}} <- parse_fields(rest, fields) do
      {:ok, {Map.put(terms, name, term), rest}}
    end
  end

  defp parse_field(data, {:reserved, reserved}) do
    size = bit_size(reserved)

    case data do
      <<^reserved::bitstring-size(size), rest::bitstring>> -> {:ok, {[], rest}}
      data -> parse_field_error(data, :reserved, expected: reserved)
    end
  end

  defp parse_field(data, {name, subfields}) when is_list(subfields) do
    case parse_fields(data, subfields) do
      {:ok, result} -> {:ok, result}
      {:error, context} -> parse_field_error(data, name, context)
    end
  end

  defp parse_field(data, {name, {:int, size}}) do
    case data do
      <<int::signed-integer-size(size), rest::bitstring>> -> {:ok, {int, rest}}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:uint, size}}) do
    case data do
      <<uint::integer-size(size), rest::bitstring>> -> {:ok, {uint, rest}}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:fp, int_size, frac_size}}) do
    case data do
      <<int::integer-size(int_size), frac::integer-size(frac_size), rest::bitstring>> ->
        {:ok, {{int, frac}, rest}}

      _unknown_format ->
        parse_field_error(data, name)
    end
  end

  defp parse_field(data, {_name, :bin}) do
    {:ok, {data, <<>>}}
  end

  defp parse_field(data, {name, {type, size}}) when type in [:bin, :str] do
    case data do
      <<bin::bitstring-size(size), rest::bitstring>> -> {:ok, {bin, rest}}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, :str}) do
    case String.split(data, "\0", parts: 2) do
      [str, rest] -> {:ok, {str, rest}}
      _unknown_format -> parse_field_error(data, name)
    end
  end

  defp parse_field(<<>>, {_name, {:list, _type}}) do
    {:ok, {[], <<>>}}
  end

  defp parse_field(data, {name, {:list, type}} = field) do
    with {:ok, {term, rest}} <- parse_field(data, {name, type}),
         {:ok, {terms, rest}} <- parse_field(rest, field) do
      {:ok, {[term | terms], rest}}
    end
  end

  defp parse_field(data, {name, _type}), do: parse_field_error(data, name)

  defp parse_field_error(data, name, context \\ [])

  defp parse_field_error(data, name, []) do
    {:error, field: name, data: data}
  end

  defp parse_field_error(_data, name, context) do
    {:error, [field: name] ++ context}
  end
end
