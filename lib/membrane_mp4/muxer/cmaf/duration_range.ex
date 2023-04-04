defmodule Membrane.MP4.Muxer.CMAF.DurationRange do
  @moduledoc false

  @enforce_keys [:min, :target]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          min: Membrane.Time.t(),
          target: Membrane.Time.t()
        }

  @spec new(Membrane.Time.t(), Membrane.Time.t()) :: t()
  def new(min, target) when min <= target do
    %__MODULE__{min: min || target, target: target}
  end

  @spec new(Membrane.Time.t()) :: t()
  def new(target) do
    %__MODULE__{min: target, target: target}
  end

  @spec validate(t()) :: :ok | {:error, :invalid_range}
  def validate(%__MODULE__{min: min, target: target}) when min <= target, do: :ok
  def validate(_range), do: {:error, :invalid_range}
end
