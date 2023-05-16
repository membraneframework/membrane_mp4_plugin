defmodule Membrane.MP4.Depayloader.AAC do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.AAC

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: Membrane.MP4.Payload

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format: AAC

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{}}
  end

  def handle_stream_format(:input, stream_format, _ctx, state) do
    content = stream_format.content
    esds_content = get_esds_content(content.esds)

    stream_format = %Membrane.AAC{
      channels: content.channels,
      encapsulation: :none,
      mpeg_version: 2,
      profile: esds_content.profile,
      sample_rate: content.sample_rate,
      samples_per_frame: esds_content.samples_per_frame
    }

    {[stream_format: {:output, stream_format}], state}
  end

  defp get_esds_content(esds) do
    elementary_stream_id = 1
    stream_priority = 0

    {esds, <<>>} = unpack_esds_section(esds, 3)

    <<^elementary_stream_id::16, ^stream_priority, rest::binary>> = esds

    {section_4, esds_section_6} = unpack_esds_section(rest, 4)
    {_section_6, <<>>} = unpack_esds_section(esds_section_6, 6)

    # 64 = mpeg4-audio
    object_type_id = 64
    # 5 = audio
    stream_type = 5
    upstream_flag = 0
    reserved_flag_set_to_1 = 1
    buffer_size = 0

    <<^object_type_id, ^stream_type::6, ^upstream_flag::1, ^reserved_flag_set_to_1::1,
      ^buffer_size::24, _max_bit_rate::32, _avg_bit_rate::32, esds_section_5::binary>> = section_4

    {section_5, <<>>} = unpack_esds_section(esds_section_5, 5)

    depends_on_core_coder = 0
    extension_flag = 0

    <<aot_id::5, _frequency_id::4, _channel_config_id::4, frame_length_id::1,
      ^depends_on_core_coder::1, ^extension_flag::1>> = section_5

    %{
      profile: AAC.aot_id_to_profile(aot_id),
      samples_per_frame: AAC.frame_length_id_to_samples_per_frame(frame_length_id)
    }
  end

  defp unpack_esds_section(section, section_no) do
    type_tag = <<128, 128, 128>>

    <<^section_no::8-integer, ^type_tag::binary-size(3), payload_size::8-integer, rest::binary>> =
      section

    <<payload::binary-size(payload_size), rest::binary>> = rest
    {payload, rest}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end
end
