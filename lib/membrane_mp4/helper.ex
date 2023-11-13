defmodule Membrane.MP4.Helper do
  @moduledoc false
  alias Membrane.Time

  @doc """
  Convert duration in `t:Membrane.Time.t/0` to duration in ticks.
  """
  @spec timescalify(Ratio.t() | integer, Ratio.t() | integer) :: integer
  def timescalify(time, timescale) do
    use Numbers, overload_operators: true
    Ratio.trunc(time * timescale / Time.second() + 0.5)
  end
end
