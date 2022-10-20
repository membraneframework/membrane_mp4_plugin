defmodule Membrane.MP4.Helper do
  @moduledoc false
  alias Membrane.Time

  @doc """
  Convert duration in `t:Membrane.Time.t/0` to duration in ticks.
  """
  @spec timescalify(Ratio.t() | integer, Ratio.t() | integer) :: integer
  def timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end

  @spec detimescalify(integer, Ratio.t() | integer) :: Membrane.Time.t()
  def detimescalify(time, timescale) do
    use Ratio
    (time / timescale) |> Ratio.trunc() |> Time.seconds()
  end
end
