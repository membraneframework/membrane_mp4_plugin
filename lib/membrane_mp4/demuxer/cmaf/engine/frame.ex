defmodule Membrane.MP4.Demuxer.CMAF.Engine.Frame do
  @moduledoc """
  Struct representing a sample returned by `Membrane.MP4.Demuxer.CMAF.Engine`.

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
