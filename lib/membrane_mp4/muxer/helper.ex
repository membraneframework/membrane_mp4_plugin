defmodule Membrane.MP4.Muxer.Helper do
  @moduledoc false
  alias Membrane.Time

  @spec timescalify(Ratio.t() | integer, Ratio.t() | integer) :: integer
  def timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end
end
