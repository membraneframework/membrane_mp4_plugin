defmodule Membrane.MP4.Demuxer.CMAF.Engine.Sample do
  @moduledoc """
  Struct representing a sample returned by .

  Timestamps are in milliseconds, as `Membrane.MP4.Demuxer.CMAF.Engine`
  is Membrane-agnostic.
  """
  @enforce_keys [:track_id, :payload, :pts, :dts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          track_id: integer(),
          payload: binary(),
          pts: integer(),
          dts: integer()
        }
end
