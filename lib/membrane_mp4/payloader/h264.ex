defmodule Membrane.MP4.Payloader.H264 do
  @moduledoc """
  Payloads H264 stream so it can be embedded in MP4.
  """
  use Bunch
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.MP4.Payload.AVC1

  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    caps: {Membrane.H264, stream_format: :byte_stream, alignment: :au, nalu_in_metadata?: true}

  def_output_pad :output, caps: Membrane.MP4.Payload

  @impl true
  def handle_init(_options) do
    {:ok, %{sps: nil, pps: nil}}
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

    grouped_nalus = Enum.group_by(nalus, & &1.metadata.h264.type)

    pps = Map.get(grouped_nalus, :pps, state.pps)
    sps = Map.get(grouped_nalus, :sps, state.sps)

    {caps, state} =
      if pps != state.pps or sps != state.sps do
        {[caps: {:output, generate_caps(ctx.pads.input.caps, nalus)}],
         %{state | pps: pps, sps: sps}}
      else
        {[], state}
      end

    payload = nalus |> Enum.map_join(&process_nalu/1)
    buffer = %Buffer{buffer | payload: payload, metadata: metadata}
    {{:ok, caps ++ [buffer: {:output, buffer}, redemand: :output]}, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  defp process_nalu(%{metadata: %{h264: %{type: type}}}) when type in [:aud, :sps, :pps] do
    <<>>
  end

  defp process_nalu(%{payload: payload}) do
    <<byte_size(payload)::integer-size(@nalu_length_size)-unit(8), payload::binary>>
  end

  defp process_metadata(metadata) do
    metadata
    |> Map.put(:mp4_payload, %{key_frame?: metadata.h264.key_frame?})
    |> pop_in([:h264, :nalus])
  end

  defp generate_caps(input_caps, nalus) do
    {timescale, _frame_duration} = input_caps.framerate

    %Membrane.MP4.Payload{
      timescale: timescale * 1024,
      width: input_caps.width,
      height: input_caps.height,
      content: %AVC1{avcc: generate_avcc(nalus)}
    }
  end

  defp generate_avcc(nalus) do
    %{sps: sps, pps: pps} = Enum.group_by(nalus, & &1.metadata.h264.type, & &1.payload)
    <<_idc_and_type, profile, compatibility, level, _rest::binary>> = hd(sps)

    <<1, profile, compatibility, level, 0b111111::6, @nalu_length_size - 1::2-integer, 0b111::3,
      length(sps)::5-integer, encode_parameter_sets(sps)::binary, length(pps)::8-integer,
      encode_parameter_sets(pps)::binary>>
  end

  defp encode_parameter_sets(pss) do
    Enum.map_join(pss, &<<byte_size(&1)::16-integer, &1::binary>>)
  end
end
