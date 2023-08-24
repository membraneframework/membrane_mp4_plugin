defmodule Membrane.MP4.Payloader.AAC do
  @moduledoc """
  Payloads AAC stream so it can be embedded in MP4.

  Resources:
  - Packaging/Encapsulation And Setup Data section of https://wiki.multimedia.cx/index.php/Understanding_AAC
  """
  use Membrane.Filter

  def_input_pad :input,
    demand_unit: :buffers,
    accepted_format: %Membrane.AAC{encapsulation: :none}

  def_output_pad :output,
    accepted_format: Membrane.MP4.Payload

  def_options avg_bit_rate: [
                spec: non_neg_integer(),
                default: 0,
                description: "Average stream bitrate. Should be set to 0 if unknown."
              ],
              max_bit_rate: [
                spec: non_neg_integer(),
                default: 0,
                description: "Maximal stream bitrate. Should be set to 0 if unknown."
              ]

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    stream_format = %Membrane.MP4.Payload{
      content: %Membrane.MP4.Payload.AAC{
        esds: make_esds(stream_format, state),
        sample_rate: stream_format.sample_rate,
        channels: stream_format.channels
      },
      timescale: stream_format.sample_rate
    }

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  defp make_esds(stream_format, state) do
    aot_id = Membrane.AAC.profile_to_aot_id(stream_format.profile)
    frequency_id = Membrane.AAC.sample_rate_to_sampling_frequency_id(stream_format.sample_rate)
    channel_config_id = Membrane.AAC.channels_to_channel_config_id(stream_format.channels)

    frame_length_id =
      Membrane.AAC.samples_per_frame_to_frame_length_id(stream_format.samples_per_frame)

    depends_on_core_coder = 0
    extension_flag = 0

    custom_frequency = if frequency_id == 15, do: <<stream_format.sample_rate::24>>, else: <<>>

    section5 =
      <<aot_id::5, frequency_id::4, custom_frequency::binary, channel_config_id::4,
        frame_length_id::1, depends_on_core_coder::1, extension_flag::1>>
      |> make_esds_section(5)

    # 64 = mpeg4-audio
    object_type_id = 64
    # 5 = audio
    stream_type = 5
    upstream_flag = 0
    reserved_flag_set_to_1 = 1
    buffer_size = 0

    section4 =
      <<object_type_id, stream_type::6, upstream_flag::1, reserved_flag_set_to_1::1,
        buffer_size::24, state.max_bit_rate::32, state.avg_bit_rate::32, section5::binary>>
      |> make_esds_section(4)

    section6 = <<2>> |> make_esds_section(6)

    elementary_stream_id = 1
    stream_priority = 0

    <<elementary_stream_id::16, stream_priority, section4::binary, section6::binary>>
    |> make_esds_section(3)
  end

  defp make_esds_section(payload, section_no) do
    type_tag = <<128, 128, 128>>
    <<section_no, type_tag::binary, byte_size(payload), payload::binary>>
  end
end
