defmodule Membrane.MP4.Demuxer.Sample do
  @moduledoc """
  Struct representing a sample returned by `Membrane.MP4.Demuxer.CMAF.Engine` 
  and `Membrane.MP4.Demuxer.ISOM.Engine`.

  Timestamps are in milliseconds, as both `Membrane.MP4.Demuxer.CMAF.Engine` 
  and `Membrane.MP4.Demuxer.ISOM.Engine` are Membrane-agnostic.
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
