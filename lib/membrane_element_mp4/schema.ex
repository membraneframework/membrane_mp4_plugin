defmodule Membrane.Element.MP4.Schema do
  use Bunch
  alias __MODULE__.Spec

  def parse(data, spec \\ Spec.spec()) do
    parse_box(data, spec, [])
  end

  def serialize(schema, spec \\ Spec.spec()) do
    do_serialize(schema, spec)
  end

  def box_path(path) do
    path |> Bunch.listify() |> Enum.flat_map(&[:children, &1]) |> Enum.drop(1)
  end

  def get_box(schema, path) do
    Bunch.Access.get_in(schema, box_path(path))
  end

  def update_box(schema, path, in_box_path \\ [], f) do
    Bunch.Access.update_in(schema, box_path(path) ++ Bunch.listify(in_box_path), f)
  end

  def update_boxes(schema, changeset) do
    changeset
    |> Bunch.listify()
    |> Enum.reduce(schema, fn
      {path, f}, schema ->
        update_box(schema, path, f)

      {path, in_box_path, f}, schema ->
        update_box(schema, path, in_box_path, f)
    end)
  end

  defp parse_box(<<>>, _schema_spec, acc) do
    Enum.reverse(acc)
  end

  defp parse_box(data, schema_spec, acc) do
    {name, content, data} = parse_box_header(data)

    if schema_spec[name] && !schema_spec[name][:black_box?] do
      schema_spec = schema_spec[name]
      {:ok, fields, rest} = schema_spec.fields.parse.(content)
      children = parse_box(rest, schema_spec.children, [])
      %{fields: fields, children: children}
    else
      %{content: content}
    end
    ~> parse_box(data, schema_spec, [{name, &1} | acc])
  end

  defp parse_box_header(data) do
    <<size::unsigned-integer-size(32)-big, name::binary-size(4), rest::binary>> = data
    content_size = size - 8
    <<content::binary-size(content_size), rest::binary>> = rest
    {parse_box_name(name), content, rest}
  end

  defp parse_box_name(name) do
    name |> String.trim_trailing(" ") |> String.to_atom()
  end

  defp do_serialize(schema, schema_spec) do
    schema
    |> Enum.map(fn {box_name, box} ->
      serialize_box(Map.put(box, :name, box_name), schema_spec[box_name])
    end)
    |> IO.iodata_to_binary()
  end

  defp serialize_box(%{content: content} = box, _schema_spec) do
    header = serialize_header(box.name, byte_size(content))
    [header, content]
  end

  defp serialize_box(box, schema_spec) do
    fields = box |> Map.get(:fields, %{}) |> schema_spec.fields.serialize.()
    children = do_serialize(box |> Map.get(:children, %{}), schema_spec.children)
    header = serialize_header(box.name, byte_size(fields) + byte_size(children))
    [header, fields, children]
  end

  defp serialize_header(name, content_size) do
    <<8 + content_size::unsigned-integer-size(32)-big, serialize_box_name(name)::binary>>
  end

  defp serialize_box_name(name) do
    Atom.to_string(name) |> String.pad_trailing(4, [" "])
  end
end
