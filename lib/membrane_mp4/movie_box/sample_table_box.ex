defmodule Membrane.MP4.MovieBox.SampleTableBox do
  @moduledoc false

  alias Membrane.MP4.{Container, Helper, Track.SampleTable}
  alias Membrane.MP4.Payload.{AAC, AVC1}
  alias Membrane.Opus

  @spec assemble(SampleTable.t()) :: Container.t()
  def assemble(table) do
    sample_description = assemble_sample_description(table.sample_description)
    sample_deltas = assemble_sample_deltas(table)
    maybe_sample_sync = maybe_sample_sync(table)
    sample_to_chunk = assemble_sample_to_chunk(table)
    sample_sizes = assemble_sample_sizes(table)
    chunk_offsets = assemble_chunk_offsets(table)

    [
      stbl: %{
        children:
          [
            stsd: %{
              children: sample_description,
              fields: %{
                entry_count: length(sample_description),
                flags: 0,
                version: 0
              }
            },
            stts: %{
              fields: %{
                version: 0,
                flags: 0,
                entry_count: length(sample_deltas),
                entry_list: sample_deltas
              }
            }
          ] ++
            maybe_sample_sync ++
            [
              stsc: %{
                fields: %{
                  version: 0,
                  flags: 0,
                  entry_count: length(sample_to_chunk),
                  entry_list: sample_to_chunk
                }
              },
              stsz: %{
                fields: %{
                  version: 0,
                  flags: 0,
                  sample_size: 0,
                  sample_count: table.sample_count,
                  entry_list: sample_sizes
                }
              },
              stco: %{
                fields: %{
                  version: 0,
                  flags: 0,
                  entry_count: length(chunk_offsets),
                  entry_list: chunk_offsets
                }
              }
            ],
        fields: %{}
      }
    ]
  end

  defp assemble_sample_description(%{content: %AVC1{} = avc1} = sample_descriptions) do
    [
      avc1: %{
        children: [
          avcC: %{
            content: avc1.avcc
          },
          pasp: %{
            children: [],
            fields: %{h_spacing: 1, v_spacing: 1}
          }
        ],
        fields: %{
          compressor_name: <<0::size(32)-unit(8)>>,
          depth: 24,
          flags: 0,
          frame_count: 1,
          height: sample_descriptions.height,
          horizresolution: {0, 0},
          num_of_entries: 1,
          version: 0,
          vertresolution: {0, 0},
          width: sample_descriptions.width
        }
      }
    ]
  end

  defp assemble_sample_description(%{content: %AAC{} = aac}) do
    [
      mp4a: %{
        children: %{
          esds: %{
            fields: %{
              elementary_stream_descriptor: aac.esds,
              flags: 0,
              version: 0
            }
          }
        },
        fields: %{
          channel_count: aac.channels,
          compression_id: 0,
          data_reference_index: 1,
          encoding_revision: 0,
          encoding_vendor: 0,
          encoding_version: 0,
          packet_size: 0,
          sample_size: 16,
          sample_rate: {aac.sample_rate, 0}
        }
      }
    ]
  end

  defp assemble_sample_description(%{content: %Opus{} = opus}) do
    [
      Opus: %{
        children: %{
          dOps: %{
            fields: %{
              version: 0,
              output_channel_count: opus.channels,
              pre_skip: 413,
              input_sample_rate: 0,
              output_gain: 0,
              channel_mapping_family: 0
            }
          }
        },
        fields: %{
          data_reference_index: 0,
          channel_count: opus.channels,
          sample_size: 16,
          sample_rate: Bitwise.bsl(48_000, 16)
        }
      }
    ]
  end

  defp assemble_sample_deltas(%{timescale: timescale, decoding_deltas: decoding_deltas}),
    do:
      Enum.map(decoding_deltas, fn %{sample_count: count, sample_delta: delta} ->
        %{sample_count: count, sample_delta: Helper.timescalify(delta, timescale)}
      end)

  defp maybe_sample_sync(%{sync_samples: []}), do: []

  defp maybe_sample_sync(%{sync_samples: sync_samples}) do
    sync_samples
    |> Enum.map(&%{sample_number: &1})
    |> then(
      &[
        stss: %{
          fields: %{
            version: 0,
            flags: 0,
            entry_count: length(&1),
            entry_list: &1
          }
        }
      ]
    )
  end

  defp assemble_sample_to_chunk(%{samples_per_chunk: samples_per_chunk}),
    do:
      Enum.map(
        samples_per_chunk,
        &%{
          first_chunk: &1.first_chunk,
          samples_per_chunk: &1.sample_count,
          sample_description_index: 1
        }
      )

  defp assemble_sample_sizes(%{sample_sizes: sample_sizes}),
    do: Enum.map(sample_sizes, &%{entry_size: &1})

  defp assemble_chunk_offsets(%{chunk_offsets: chunk_offsets}),
    do: Enum.map(chunk_offsets, &%{chunk_offset: &1})

  @spec unpack(%{children: Container.t(), fields: map()}) :: SampleTable.t()
  def unpack(%{children: boxes}) do
    %SampleTable{
      sample_description: unpack_sample_description(boxes[:stsd]),
      sample_count: boxes[:stsz].fields.sample_count,
      sample_sizes: unpack_sample_sizes(boxes[:stsz]),
      chunk_offsets: unpack_chunk_offsets(boxes[:stco]),
      decoding_deltas: boxes[:stts].fields.entry_list,
      samples_per_chunk: boxes[:stsc].fields.entry_list
    }
  end

  defp unpack_chunk_offsets(%{fields: %{entry_list: offsets}}) do
    offsets |> Enum.map(fn %{chunk_offset: offset} -> offset end)
  end

  defp unpack_sample_sizes(%{fields: %{entry_list: sizes}}) do
    sizes |> Enum.map(fn %{entry_size: size} -> size end)
  end

  defp unpack_sample_description(%{children: definitions}) do
    [{codec, %{fields: fields} = data}] = definitions

    %{
      content: unpack_content(codec, data),
      height: Map.get(fields, :height, 0),
      width: Map.get(fields, :width, 0)
    }
  end

  defp unpack_content(:avc1, %{children: boxes}) do
    %AVC1{avcc: boxes[:avcC].content, inband_parameters?: false}
  end

  defp unpack_content(:mp4a, %{children: boxes, fields: fields}) do
    %AAC{
      esds: boxes[:esds].fields.elementary_stream_descriptor,
      sample_rate: fields.sample_rate |> elem(0),
      channels: fields.channel_count
    }
  end

  defp unpack_content(:Opus, %{children: boxes}) do
    %Opus{channels: boxes[:dOps].fields.output_channel_count, self_delimiting?: false}
  end
end
