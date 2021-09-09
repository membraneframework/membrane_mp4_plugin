defmodule Membrane.MP4.Muxer.Box do
  @moduledoc false
  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.Track
  alias Membrane.MP4.Payload.{AAC, AVC1}

  @ftyp [
    ftyp: %{
      children: [],
      fields: %{
        compatible_brands: ["iso6", "mp41"],
        major_brand: "iso5",
        major_brand_version: 512
      }
    }
  ]

  @ftyp_size @ftyp |> Container.serialize!() |> byte_size()
  @mdat_header_size 8
  @first_chunk_offset @ftyp_size + @mdat_header_size

  @spec file_type_box :: Container.t()
  def file_type_box(), do: @ftyp

  @spec media_data_box(binary) :: Container.t()
  def media_data_box(payload) do
    [
      mdat: %{
        content: payload
      }
    ]
  end

  @spec movie_box([%Track{}], integer) :: Container.t()
  def movie_box(tracks, common_timescale) do
    longest_track = Enum.max_by(tracks, & &1.common_duration)

    header =
      %{
        timescale: common_timescale,
        duration: longest_track.common_duration,
        next_track_id: length(tracks) + 1
      }
      |> movie_header()

    track_boxes = tracks |> Enum.flat_map(&track_box/1)

    [
      moov: %{
        children: header ++ track_boxes,
        fields: %{}
      }
    ]
  end

  defp movie_header(%{
         duration: duration,
         timescale: timescale,
         next_track_id: next_track_id
       }) do
    [
      mvhd: %{
        children: [],
        fields: %{
          creation_time: 0,
          duration: duration,
          flags: 0,
          matrix_value_A: {1, 0},
          matrix_value_B: {0, 0},
          matrix_value_C: {0, 0},
          matrix_value_D: {1, 0},
          matrix_value_U: {0, 0},
          matrix_value_V: {0, 0},
          matrix_value_W: {1, 0},
          matrix_value_X: {0, 0},
          matrix_value_Y: {0, 0},
          modification_time: 0,
          next_track_id: next_track_id,
          quicktime_current_time: 0,
          quicktime_poster_time: 0,
          quicktime_preview_duration: 0,
          quicktime_preview_time: 0,
          quicktime_selection_duration: 0,
          quicktime_selection_time: 0,
          rate: {1, 0},
          timescale: timescale,
          version: 0,
          volume: {1, 0}
        }
      }
    ]
  end

  defp track_box(track) do
    [
      trak: %{
        children:
          track_header(track) ++
            [
              mdia: %{
                children:
                  media_handler_header(track) ++
                    handler(track) ++
                    [
                      minf: %{
                        children:
                          media_header(track) ++
                            [
                              dinf: %{
                                children: [
                                  dref: %{
                                    children: [
                                      url: %{children: [], fields: %{flags: 1, version: 0}}
                                    ],
                                    fields: %{entry_count: 1, flags: 0, version: 0}
                                  }
                                ],
                                fields: %{}
                              }
                            ] ++ sample_table(track),
                        fields: %{}
                      }
                    ],
                fields: %{}
              }
            ],
        fields: %{}
      }
    ]
  end

  defp track_header(track) do
    [
      tkhd: %{
        children: [],
        fields: %{
          alternate_group: 0,
          creation_time: 0,
          duration: track.common_duration,
          flags: 3,
          height: {track.metadata.height, 0},
          layer: 0,
          matrix_value_A: {1, 0},
          matrix_value_B: {0, 0},
          matrix_value_C: {0, 0},
          matrix_value_D: {1, 0},
          matrix_value_U: {0, 0},
          matrix_value_V: {0, 0},
          matrix_value_W: {1, 0},
          matrix_value_X: {0, 0},
          matrix_value_Y: {0, 0},
          modification_time: 0,
          track_id: track.id,
          version: 0,
          volume: {1, 0},
          width: {track.metadata.width, 0}
        }
      }
    ]
  end

  defp media_handler_header(track) do
    [
      mdhd: %{
        children: [],
        fields: %{
          creation_time: 0,
          duration: track.duration,
          flags: 0,
          language: 21956,
          modification_time: 0,
          timescale: track.metadata.timescale,
          version: 0
        }
      }
    ]
  end

  defp handler(%Track{metadata: %{content: %AVC1{}}}) do
    [
      hdlr: %{
        children: [],
        fields: %{
          flags: 0,
          handler_type: "vide",
          name: "VideoHandler",
          version: 0
        }
      }
    ]
  end

  defp handler(%Track{metadata: %{content: %AAC{}}}) do
    [
      hdlr: %{
        children: [],
        fields: %{
          flags: 0,
          handler_type: "soun",
          name: "SoundHandler",
          version: 0
        }
      }
    ]
  end

  defp media_header(%Track{metadata: %{content: %AVC1{}}}) do
    [
      vmhd: %{
        children: [],
        fields: %{
          flags: 1,
          graphics_mode: 0,
          opcolor: 0,
          version: 0
        }
      }
    ]
  end

  defp media_header(%Track{metadata: %{content: %AAC{}}}) do
    [
      smhd: %{
        children: [],
        fields: %{
          balance: {0, 0},
          flags: 0,
          version: 0
        }
      }
    ]
  end

  defp sample_table(track) do
    sample_description = sample_description(track)
    time_to_sample = time_to_sample(track)
    stts = sync_sample(track)
    sample_to_chunk = sample_to_chunk(track)
    sample_size = sample_size(track)
    chunk_offset = chunk_offset(track)

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
                entry_count: length(time_to_sample),
                entry_list: time_to_sample
              }
            }
          ] ++
            stts ++
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
                  sample_count: track.sample_count,
                  entry_list: sample_size
                }
              },
              stco: %{
                fields: %{
                  version: 0,
                  flags: 0,
                  entry_count: length(chunk_offset),
                  entry_list: chunk_offset
                }
              }
            ],
        fields: %{}
      }
    ]
  end

  defp sample_description(%Track{metadata: %{content: %AVC1{} = avc1}} = track) do
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
          height: track.metadata.height,
          horizresolution: {0, 0},
          num_of_entries: 1,
          version: 0,
          vertresolution: {0, 0},
          width: track.metadata.width
        }
      }
    ]
  end

  defp sample_description(%Track{metadata: %{content: %AAC{} = aac}}) do
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

  defp time_to_sample(track) do
    [
      %{
        sample_count: track.sample_count,
        sample_delta: div(track.duration, track.sample_count)
      }
    ]
  end

  defp sync_sample(%Track{metadata: %{content: %AVC1{}}} = track) do
    sync_sample = track.key_frames |> Enum.map(&%{sample_number: &1})

    [
      stss: %{
        fields: %{
          version: 0,
          flags: 0,
          entry_count: length(sync_sample),
          entry_list: sync_sample
        }
      }
    ]
  end

  defp sync_sample(_track) do
    []
  end

  defp sample_to_chunk(%{samples_per_chunk: n, samples_in_last_chunk: n}) do
    [
      %{
        first_chunk: 1,
        samples_per_chunk: n,
        sample_description_index: 1
      }
    ]
  end

  defp sample_to_chunk(track) do
    [
      %{
        first_chunk: 1,
        samples_per_chunk: track.samples_per_chunk,
        sample_description_index: 1
      },
      %{
        first_chunk: track.chunks_flushed,
        samples_per_chunk: track.samples_in_last_chunk,
        sample_description_index: 1
      }
    ]
  end

  defp sample_size(track) do
    Enum.map(track.sample_sizes, &%{entry_size: &1})
  end

  defp chunk_offset(track) do
    Enum.map(track.chunk_offsets, &%{chunk_offset: @first_chunk_offset + &1})
  end
end
