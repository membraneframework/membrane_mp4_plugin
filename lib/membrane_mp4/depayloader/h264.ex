defmodule Membrane.MP4.Depayloader.H264 do
  @moduledoc """
  Depayloads H264 stream.
  """

  use Membrane.Bin

  alias Membrane.MP4.Depayloader
  alias Membrane.H264.Parser

  def_input_pad :input,
    demand_unit: :buffers,
    accepted_format: Membrane.MP4.Payload

  def_output_pad :output,
    accepted_format: %Membrane.H264{alignment: :au, nalu_in_metadata?: true}

  @impl true
  def handle_init(_ctx, _opts) do
    spec =
      bin_input()
      |> child(:remote_stream_depayloader, Depayloader.H264.RemoteStream)
      |> child(:parser, Parser)
      |> bin_output()
    {[spec: spec], %{}}
  end
end
