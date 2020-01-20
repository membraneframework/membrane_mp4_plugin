defmodule Membrane.Element.MP4.Depayloader.AAC do
  def parse_esds(data) do
    do_parse_esds(data, [])
  end

  defp do_parse_esds(<<>>, acc) do
    Enum.reverse(acc)
  end

  defp do_parse_esds(data, acc) do
    {result, rest} = parse_esds_section(data)
    do_parse_esds(rest, [result | acc])
  end

  defp parse_esds_section(<<3, data::binary>>) do
    data = skip_type_tag(data)
    <<length, es_id::16, priority, rest::binary>> = data
    {%{length: length, es_id: es_id, priority: priority}, rest}
  end

  defp parse_esds_section(<<4, data::binary>>) do
    data = skip_type_tag(data)

    <<length, object_id, stream_type::6, upstream_flag::1, 1::1, buffer_size::24,
      max_bit_rate::32, avg_bit_rate::32, rest::binary>> = data

    {%{
       length: length,
       object_id: object_id,
       stream_type: stream_type,
       upstream_flag: upstream_flag,
       buffer_size: buffer_size,
       max_bit_rate: max_bit_rate,
       avg_bit_rate: avg_bit_rate
     }, rest}
  end

  defp parse_esds_section(<<5, data::binary>>) do
    data = skip_type_tag(data)

    <<length, profile_id::5, frequency_id::4, channel_setup_id::4, frame_length_id::1,
      depends_on_core_coder::1, extension_flag::1, rest::binary>> = data

    {%{
       length: length,
       profile_id: profile_id,
       frequency_id: frequency_id,
       channel_setup_id: channel_setup_id,
       frame_length_id: frame_length_id,
       depends_on_core_coder: depends_on_core_coder,
       extension_flag: extension_flag
     }, rest}
  end

  defp parse_esds_section(<<6, data::binary>>) do
    data = skip_type_tag(data)
    <<length, 2, rest::binary>> = data
    {{%{length: length}}, rest}
  end

  defp skip_type_tag(<<128, rest::binary>>), do: skip_type_tag(rest)
  defp skip_type_tag(data), do: data
end
