defmodule Membrane.MP4.Container.Header do
  @moduledoc """
  A structure describing the header of the box.

  The `content_size` field is equal to the box size minus the size of the header (8 bytes).
  """

  @enforce_keys [:name, :content_size]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: atom(),
          content_size: non_neg_integer()
        }

  @name_size 4
  @size_size 4
  @header_size @name_size + @size_size

  @doc """
  Parses the box's header.

  Returns the `t:t/0` and the leftover data.
  """
  @spec parse(binary()) :: {:ok, t, leftover :: binary()} | {:error, :not_enough_data}
  def parse(data) do
    with <<size::integer-size(@size_size)-unit(8), name::binary-size(@name_size), rest::binary>> <-
           data do
      {:ok,
       %__MODULE__{
         name: parse_box_name(name),
         content_size: size - @header_size
       }, rest}
    else
      _error -> {:error, :not_enough_data}
    end
  end

  defp parse_box_name(name) do
    name |> String.trim_trailing(" ") |> String.to_atom()
  end
end
