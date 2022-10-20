defmodule Membrane.MP4.Demuxer.ISOM do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}

  def_input_pad :input,
    caps: {RemoteStream, type: :bytestream, content_format: one_of([nil, MP4])},
    demand_unit: :buffers

  def_output_pad :output,
    caps: Membrane.MP4.Payload,
    availability: :on_request
end
