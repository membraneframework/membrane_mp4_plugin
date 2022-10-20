defmodule Membrane.MP4.Container do
  @moduledoc """
  Module for parsing and serializing MP4 files.

  Bases on MP4 structure specification from `#{inspect(__MODULE__)}.Schema`.
  """
  use Bunch
  alias __MODULE__.{ParseHelper, Schema, SerializeHelper}

  @schema Schema.schema()

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

  Returns boxes that have been correctly parsed, and the leftover data that
  is insufficient to constitute a complete box.
  """
  @spec parse(binary) :: {:ok, t, leftover :: binary()} | {:error, parse_error_context_t}
  def parse(data) do
    parse(data, @schema)
  end

  @doc """
  Parses binary data to MP4 according to a custom schema.

  Returns boxes that have been correctly parsed, and the leftover data that
  is insufficient to constitute a complete box.
  """
  @spec parse(binary, Schema.t()) ::
          {:ok, t, leftover :: binary()} | {:error, parse_error_context_t}
  def parse(data, schema) do
    case ParseHelper.parse_boxes(data, schema, %{}, []) do
      {:ok, boxes, rest, _storage} -> {:ok, boxes, rest}
      error -> error
    end
  end

  @doc """
  Same as `parse/1`, raises on error.
  """
  @spec parse!(binary) :: {t, leftover :: binary()}
  def parse!(data) do
    parse!(data, @schema)
  end

  @doc """
  Same as `parse/2`, raises on error.
  """
  @spec parse!(binary, Schema.t()) :: {t, leftover :: binary()}
  def parse!(data, schema) do
    case ParseHelper.parse_boxes(data, schema, %{}, []) do
      {:ok, boxes, rest, _storage} ->
        {boxes, rest}

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
    case SerializeHelper.serialize_boxes(mp4, schema, %{}) do
      {{:ok, result}, _storage} -> {:ok, result}
      {{:error, context}, _storage} -> {:error, context}
    end
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
    case SerializeHelper.serialize_boxes(mp4, schema, %{}) do
      {{:ok, data}, _storage} ->
        data

      {{:error, context}, _storage} ->
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
end
