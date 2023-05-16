defmodule Membrane.MP4.Depayloader.H264 do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.H264

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: Membrane.MP4.Payload

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format: %H264.RemoteStream{alignment: :au}

  @annex_b_prefix <<0, 0, 0, 1>>

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{nalu_length_size: nil}}
  end

  def handle_stream_format(:input, stream_format, _ctx, state) do
    avcc = stream_format.content.avcc
    state = %{state | nalu_length_size: get_nalu_length_size(avcc)}
    {[stream_format: {:output, %H264.RemoteStream{alignment: :au}}], state}
  end

  defp get_nalu_length_size(avcc) do
    <<1, _profile, _compatibility, _level, 0b111111::6, nalu_length_size_minus_one::2-integer,
    _rest::binary>> = avcc
    nalu_length_size_minus_one+1
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    buffer = %Buffer{buffer | payload: to_annex_b(buffer.payload, state.nalu_length_size)}
    {[buffer: {:output, buffer}], state}
  end

  defp to_annex_b(au_payload, nalu_length_size) do
    <<nalu_size::integer-size(nalu_length_size)-unit(8), rest::binary>> = au_payload
    <<nalu::binary-size(nalu_size), rest::binary>> = rest

    if rest != <<>> do
      @annex_b_prefix <> nalu <> to_annex_b(rest, nalu_length_size)
    else
      @annex_b_prefix <> nalu
    end
  end
end
