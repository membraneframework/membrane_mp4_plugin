defmodule Membrane.MP4.Muxer.CMAF.RequestMediaFinalizeSender do
  @moduledoc """
  Filter responsbile for sending `Membrane.MP4.Muxer.CMAF.RequestMediaFinalization` event
  to its input pad on a request.
  """
  use Membrane.Filter

  def_options parent: [
                spec: pid(),
                description: """
                Parent process that is responsible for 
                triggering request send.
                """
              ]

  def_input_pad :input,
    availability: :always,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: _any

  def_output_pad :output,
    availability: :always,
    demand_mode: :auto,
    accepted_format: _any

  @spec send_request(pid()) :: :ok
  def send_request(sender) do
    send(sender, :send_request)

    :ok
  end

  @impl true
  def handle_init(_ctx, %__MODULE__{parent: parent}) do
    send(parent, {:media_finalize_request_sender, self()})

    {[], %{}}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_info(:send_request, _ctx, state) do
    {[event: {:input, %Membrane.MP4.Muxer.CMAF.RequestMediaFinalization{}}], state}
  end
end
