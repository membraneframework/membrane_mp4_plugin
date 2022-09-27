defmodule Membrane.MP4.Demuxer.ISOM do
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}

  def_input_pad :input,
    caps: {RemoteStream, type: :bytestream, content_format: one_of([nil, MP4])},
    demand_unit: :buffers

  def_output_pad :output,
    caps: Membrane.MP4.Payload,
    availability: :on_request

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()

    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
  end
end
