defmodule Membrane.MP4.Container.PackedList do
  @moduledoc """
  A list of fixed-width entries kept in their serialized form and decoded on enumeration.

  Boxes such as `stsz` or `stco` can hold hundreds of thousands of entries, so decoding
  them eagerly into maps costs an order of magnitude more memory than the box itself.
  """

  alias Membrane.MP4.Container.ParseHelper

  @enforce_keys [:data, :type, :width, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          data: bitstring(),
          type: term(),
          width: pos_integer(),
          context: %{atom() => integer()}
        }

  defimpl Enumerable do
    @impl true
    def count(%{data: data, width: width}), do: {:ok, div(bit_size(data), width)}

    @impl true
    def member?(_list, _entry), do: {:error, __MODULE__}

    @impl true
    def slice(_list), do: {:error, __MODULE__}

    @impl true
    def reduce(_list, {:halt, acc}, _fun) do
      {:halted, acc}
    end

    def reduce(list, {:suspend, acc}, fun) do
      {:suspended, acc, &reduce(list, &1, fun)}
    end

    def reduce(%{data: <<>>}, {:cont, acc}, _fun) do
      {:done, acc}
    end

    def reduce(%{data: data, width: width} = list, {:cont, acc}, fun) do
      <<entry::bitstring-size(^width), rest::bitstring>> = data
      {:ok, {term, <<>>}, _context} = ParseHelper.parse_entry(entry, list.type, list.context)
      reduce(%{list | data: rest}, fun.(term, acc), fun)
    end
  end

  defimpl Inspect do
    @impl true
    def inspect(list, _opts),
      do: "#Membrane.MP4.Container.PackedList<#{Enum.count(list)} entries>"
  end
end
