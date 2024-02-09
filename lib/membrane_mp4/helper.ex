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

  @doc """
  Check whether a sample is a key frame. Returns `true` for non video samples
  """
  @spec key_frame?(Membrane.Buffer.metadata()) :: boolean()
  def key_frame?(%{h264: %{key_frame?: false}}), do: false
  def key_frame?(%{h265: %{key_frame?: false}}), do: false
  def key_frame?(_metadata), do: true
end
