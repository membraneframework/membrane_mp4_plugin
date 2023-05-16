defmodule Membrane.MP4.Depayloader.H264.RemoteStream do
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
    {[], %{nalu_length_size: nil, sps: <<>>, pps: <<>>}}
  end

  def handle_stream_format(:input, stream_format, _ctx, state) do
    avcc = stream_format.content.avcc
    state = %{state | nalu_length_size: get_nalu_length_size(avcc)}
    {list_of_sps, list_of_pps} = decode_pss(avcc)
    state = %{state | sps: list_of_sps, pps: list_of_pps}
    {[stream_format: {:output, %H264.RemoteStream{alignment: :au}}], state}
  end

  defp get_nalu_length_size(avcc) do
    <<1, _profile, _compatibility, _level, 0b111111::6, nalu_length_size_minus_one::2-integer,
    _rest::binary>> = avcc
    nalu_length_size_minus_one+1
  end

  defp decode_pss(avcc) do
    <<1, _profile, _compatibility, _level, 0b111111::6, _nalu_length_size_minus_one::2-integer, 0b111::3,
      num_of_seq_params_sets::5-integer, rest::binary>> = avcc
    {annex_b_list_of_sps, rest} = to_annex_b(rest, 2, num_of_seq_params_sets)
    <<num_of_pic_params_sets::8-integer, rest::binary>> = rest
    {annex_b_list_of_pps, rest} = to_annex_b(rest, 2, num_of_seq_params_sets)
    {annex_b_list_of_sps, annex_b_list_of_pps}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {annex_b_payload, <<>>} = to_annex_b(buffer.payload, state.nalu_length_size)
    buffer = %Buffer{buffer | payload: state.sps<>state.pps<>annex_b_payload}

    state = %{state | sps: <<>>, pps: <<>>}
    {[buffer: {:output, buffer}], state}
  end

  defp to_annex_b(au_payload, _nalu_length_size, 0 = _iterations_left) do
    {<<>>, au_payload}
  end

  defp to_annex_b(<<>> = au_payload, _nalu_length_size, _iterations_left) do
    {<<>>, au_payload}
  end

  defp to_annex_b(au_payload, nalu_length_size, iterations_left \\ :infinity) do
    iterations_left =
      case iterations_left do
        :infinity -> :infinity
        _ -> iterations_left - 1
      end
    <<nalu_size::integer-size(nalu_length_size)-unit(8), rest::binary>> = au_payload
    <<nalu::binary-size(nalu_size), rest::binary>> = rest
    {annex_b, out_of_iterations_rest} = to_annex_b(rest, nalu_length_size, iterations_left)
    {@annex_b_prefix <> nalu <> annex_b, out_of_iterations_rest}
  end
end
