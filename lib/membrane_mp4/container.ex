defmodule Membrane.MP4.Container do
  @moduledoc """
  Module for parsing and serializing MP4 files.

  Bases on MP4 structure specification from `#{inspect(__MODULE__)}.Schema`.
  """
  use Bunch
  alias __MODULE__.Schema

  @schema Schema.schema()
  @box_name_size 4
  @box_size_size 4
  @box_header_size @box_name_size + @box_size_size

  @type box_name_t :: atom
  @type field_name_t :: atom
  @type fields_t :: %{field_name_t => term | [term] | fields_t()}
  @type t :: [{box_name_t, %{content: binary} | %{fields: fields_t, children: t}}]

  @type parse_error_context_t :: [
          {:box, box_name_t}
          | {:field, field_name_t}
          | {:data, bitstring}
          | {:reason, :box_header | {:box_size, header: pos_integer, actual: pos_integer}}
        ]

  @type serialize_error_context_t :: [{:box, box_name_t} | {:field, field_name_t}]

  @doc """
  Parses binary data to MP4 according to `#{inspect(Schema)}.schema/0`.
  """
  @spec parse(binary) :: {:ok, t} | {:error, parse_error_context_t}
  def parse(data) do
    parse(data, @schema)
  end

  @doc """
  Parses binary data to MP4 according to a custom schema.
  """
  @spec parse(binary, Schema.t()) :: {:ok, t} | {:error, parse_error_context_t}
  def parse(data, schema) do
    parse_box(data, schema, [])
  end

  @doc """
  Same as `parse/1`, raises on error.
  """
  @spec parse!(binary) :: t
  def parse!(data) do
    parse!(data, @schema)
  end

  @doc """
  Same as `parse/2`, raises on error.
  """
  @spec parse!(binary, Schema.t()) :: t
  def parse!(data, schema) do
    case parse_box(data, schema, []) do
      {:ok, mp4} ->
        mp4

      {:error, context} ->
        raise """
        Error parsing MP4
        box: #{Keyword.get_values(context, :box) |> Enum.join(" / ")}
        field: #{Keyword.get_values(context, :field) |> Enum.join(" / ")}
        data: #{Keyword.get(context, :data) |> inspect()}
        reason: #{Keyword.get(context, :reason) |> inspect(pretty: true)}
        """
    end
  end

  @doc """
  Serializes MP4 to a binary according to `#{inspect(Schema)}.schema/0`.
  """
  @spec serialize(t) :: {:ok, binary} | {:error, serialize_error_context_t}
  def serialize(mp4) do
    serialize(mp4, @schema)
  end

  @doc """
  Serializes MP4 to a binary according to a custom schema.
  """
  @spec serialize(t, Schema.t()) :: {:ok, binary} | {:error, serialize_error_context_t}
  def serialize(mp4, schema) do
    do_serialize(mp4, schema)
  end

  @doc """
  Same as `serialize/1`, raises on error
  """
  @spec serialize!(t) :: binary
  def serialize!(mp4) do
    serialize!(mp4, @schema)
  end

  @doc """
  Same as `serialize/2`, raises on error
  """
  @spec serialize!(t, Schema.t()) :: binary
  def serialize!(mp4, schema) do
    case do_serialize(mp4, schema) do
      {:ok, data} ->
        data

      {:error, context} ->
        box = Keyword.get_values(context, :box)

        raise """
        Error serializing MP4
        box: #{Enum.join(box, " / ")}
        field: #{Keyword.get_values(context, :field) |> Enum.join(" / ")}
        box contents:
        #{get_box(mp4, box) |> inspect(pretty: true)}
        """
    end
  end

  @doc """
  Maps a path in the MP4 box tree into sequence of keys under which that
  box resides in MP4.
  """
  @spec box_path(box_name_t | [box_name_t]) :: [atom]
  def box_path(path) do
    path |> Bunch.listify() |> Enum.flat_map(&[:children, &1]) |> Enum.drop(1)
  end

  @doc """
  Gets a box from a given path in a parsed MP4.
  """
  @spec get_box(t, box_name_t | [box_name_t]) :: t
  def get_box(mp4, path) do
    Bunch.Access.get_in(mp4, box_path(path))
  end

  @doc """
  Updates a box at a given path in a parsed MP4.

  If `parameter_path` is set, a parameter within a box is updated.
  """
  @spec update_box(t, box_name_t | [box_name_t], [atom], (term -> term)) :: t
  def update_box(mp4, path, parameter_path \\ [], f) do
    Bunch.Access.update_in(mp4, box_path(path) ++ Bunch.listify(parameter_path), f)
  end

  defp parse_box(<<>>, _schema, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp parse_box(data, schema, acc) do
    withl header: {:ok, {name, content, data}} <- parse_box_header(data),
          do: box_schema = schema[name],
          known?: true <- box_schema && not box_schema.black_box?,
          try: {:ok, {fields, rest}} <- parse_fields(content, box_schema.fields),
          try: {:ok, children} <- parse_box(rest, box_schema.children, []) do
      box = %{fields: fields, children: children}
      parse_box(data, schema, [{name, box} | acc])
    else
      header: error ->
        error

      known?: false ->
        box = %{content: content}
        parse_box(data, schema, [{name, box} | acc])

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

  defp do_serialize(mp4, schema) do
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
         {:ok, children} <- do_serialize(Map.get(box, :children, %{}), schema.children) do
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
      _ -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:uint, size}}) do
    case data do
      <<uint::integer-size(size), rest::bitstring>> -> {:ok, {uint, rest}}
      _ -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, {:fp, int_size, frac_size}}) do
    case data do
      <<int::integer-size(int_size), frac::integer-size(frac_size), rest::bitstring>> ->
        {:ok, {{int, frac}, rest}}

      _ ->
        parse_field_error(data, name)
    end
  end

  defp parse_field(data, {_name, :bin}) do
    {:ok, {data, <<>>}}
  end

  defp parse_field(data, {name, {type, size}}) when type in [:bin, :str] do
    case data do
      <<bin::bitstring-size(size), rest::bitstring>> -> {:ok, {bin, rest}}
      _ -> parse_field_error(data, name)
    end
  end

  defp parse_field(data, {name, :str}) do
    case String.split(data, "\0", parts: 2) do
      [str, rest] -> {:ok, {str, rest}}
      _ -> parse_field_error(data, name)
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
