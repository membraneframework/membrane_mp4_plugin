defmodule Membrane.MP4.Payloader.H264 do
  @moduledoc """
  Payloads H264 stream so it can be embedded in MP4.
  """
  use Bunch
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.MP4.Payload.AVC1

  @nalu_length_size 4
  @parameter_nalus MapSet.new([:sps, :pps, :aus])

  def_input_pad :input,
    demand_unit: :buffers,
    caps: {Membrane.H264, stream_format: :byte_stream, alignment: :au, nalu_in_metadata?: true}

  def_output_pad :output, caps: Membrane.MP4.Payload

  def_options parameters_in_band?: [
                spec: boolean(),
                default: false,
                description: """
                Determines whether the parameter type nalus will be removed from the stream.
                Inband parameters seem to be legal with MP4, but some players don't respond kindly to them, so use at your own risk.

                NALUs currently considered to be parameters: #{Enum.map_join(@parameter_nalus, ",", &inspect/1)}
                """
              ]

  @impl true
  def handle_init(%__MODULE__{} = options) do
    {:ok, %{sps: nil, pps: nil, parameters_in_band?: options.parameters_in_band?}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, ctx, state) do
    {nalus, metadata} = process_metadata(buffer.metadata)

    nalus =
      Enum.map(nalus, &Map.put(&1, :payload, :binary.part(buffer.payload, &1.unprefixed_poslen)))

    # Given that the buffer has :au alignment, we don't need to consider the entire buffer - parameter sets should be at the very beginning
    grouped_nalus =
      nalus
      |> Enum.take_while(&(&1.metadata.h264.type in [:sei, :sps, :pps]))
      |> Enum.map(&{&1.metadata.h264.type, &1.payload})

    pps = Keyword.get_values(grouped_nalus, :pps)
    sps = Keyword.get_values(grouped_nalus, :sps)

    {caps, state} =
      if (pps != [] and pps != state.pps) or (sps != [] and sps != state.sps) do
        {[
           caps:
             {:output, generate_caps(ctx.pads.input.caps, pps, sps, state.parameters_in_band?)}
         ], %{state | pps: pps, sps: sps}}
      else
        {[], state}
      end

    payload =
      nalus
      |> maybe_remove_parameter_nalus(state)
      |> Enum.map_join(&to_length_prefixed/1)

    buffer = %Buffer{buffer | payload: payload, metadata: metadata}
    {{:ok, caps ++ [buffer: {:output, buffer}, redemand: :output]}, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  defp maybe_remove_parameter_nalus(nalus, %{parameters_in_band?: false}) do
    Enum.reject(nalus, &MapSet.member?(@parameter_nalus, &1.metadata.h264.type))
  end

  defp maybe_remove_parameter_nalus(nalus, _state), do: nalus

  defp to_length_prefixed(%{payload: payload}) do
    <<byte_size(payload)::integer-size(@nalu_length_size)-unit(8), payload::binary>>
  end

  defp process_metadata(metadata) do
    metadata
    |> Map.put(:mp4_payload, %{key_frame?: metadata.h264.key_frame?})
    |> pop_in([:h264, :nalus])
  end

  defp generate_caps(input_caps, pps, sps, inband_parameters?) do
    timescale =
      case input_caps.framerate do
        {0, _denominator} -> 30 * 1024
        {nominator, _denominator} -> nominator * 1024
      end

    %Membrane.MP4.Payload{
      timescale: timescale,
      width: input_caps.width,
      height: input_caps.height,
      content: %AVC1{avcc: generate_avcc(pps, sps), inband_parameters?: inband_parameters?}
    }
  end

  defp generate_avcc(pps, sps) do
    <<_idc_and_type, profile, compatibility, level, _rest::binary>> = hd(sps)

    <<1, profile, compatibility, level, 0b111111::6, @nalu_length_size - 1::2-integer, 0b111::3,
      length(sps)::5-integer, encode_parameter_sets(sps)::binary, length(pps)::8-integer,
      encode_parameter_sets(pps)::binary>>
  end

  defp encode_parameter_sets(pss) do
    Enum.map_join(pss, &<<byte_size(&1)::16-integer, &1::binary>>)
  end
end
