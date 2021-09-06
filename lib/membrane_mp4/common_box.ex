defmodule Membrane.MP4.CommonBox do
  @moduledoc false
  alias Membrane.MP4.{Container, Track}
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
  @mdat_header_size [mdat: %{content: <<>>}] |> Container.serialize!() |> byte_size()

  @spec file_type_box :: keyword()
  def file_type_box(), do: @ftyp

  @spec media_data_box(binary) :: keyword()
  def media_data_box(payload) do
    [
      mdat: %{
        content: payload
      }
    ]
  end

  @spec movie_box([%Track{}], integer, keyword()) :: keyword()
  def movie_box(tracks, timescale, offsets, extensions \\ []) do
    longest_track = Enum.max_by(tracks, & &1.duration.normalized)

    header =
      %{
        timescale: timescale,
        duration: longest_track.duration.normalized,
        next_track_id: length(tracks) + 1
      }
      |> movie_header()

    track_boxes = tracks |> Enum.zip(offsets) |> Enum.flat_map(&track_box(elem(&1, 0), elem(&1, 1)))

    [
      moov: %{
        children: header ++ track_boxes ++ extensions,
        fields: %{}
      }
    ]
  end

  @spec track_box(%Track{}, integer) :: keyword()
  defp track_box(track, offset) do
    track_header = track_header(track)
    media_handler_header = media_handler_header(track)
    handler = handler(track)
    media_header = media_header(track)
    sample_table = sample_table(track, offset)

    [
      trak: %{
        children:
          track_header ++
            [
              mdia: %{
                children:
                  media_handler_header ++
                    handler ++
                    [
                      minf: %{
                        children:
                          media_header ++
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
                            ] ++ sample_table,
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

  defp track_header(track) do
    [
      tkhd: %{
        children: [],
        fields: %{
          alternate_group: 0,
          creation_time: 0,
          duration: track.duration.normalized,
          flags: 3,
          height: {track.height, 0},
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
          width: {track.width, 0}
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
          duration: track.duration.absolute,
          flags: 0,
          language: 21956,
          modification_time: 0,
          timescale: track.timescale,
          version: 0
        }
      }
    ]
  end

  defp handler(%Track{content: %AVC1{}}) do
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

  defp handler(%Track{content: %AAC{}}) do
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

  defp media_header(%Track{content: %AVC1{}}) do
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

  defp media_header(%Track{content: %AAC{}}) do
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

  defp sample_table(%Track{sample_count: 0} = track, _offset) do
    sample_description = sample_description(track)

    [
      stbl: %{
        children: [
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
              entry_count: 0,
              entry_list: []
            }
          },
          stsc: %{
            fields: %{
              version: 0,
              flags: 0,
              entry_count: 0,
              entry_list: []
            }
          },
          stsz: %{
            fields: %{
              version: 0,
              flags: 0,
              sample_size: 0,
              sample_count: 0,
              entry_list: []
            }
          },
          stco: %{
            fields: %{
              version: 0,
              flags: 0,
              entry_count: 0,
              entry_list: []
            }
          }
        ],
        fields: %{}
      }
    ]
  end

  defp sample_table(track, offset) do
    sample_description = sample_description(track)

    sample_delta = div(track.duration.absolute, track.sample_count)
    entry_sizes = Enum.map(track.buffers, &%{entry_size: byte_size(&1.payload)})
    chunk_offset = @ftyp_size + @mdat_header_size + offset

    [
      stbl: %{
        children: [
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
              entry_count: 1,
              entry_list: [
                %{
                  sample_count: track.sample_count,
                  sample_delta: sample_delta
                }
              ]
            }
          },
          # stss: %{
          #   fields: %{
          #     version: 0,
          #     flags: 0,
          #     entry_count: 1,
          #     entry_list: [
          #       %{sample_number: 1}
          #     ]
          #   }
          # },
          stsc: %{
            fields: %{
              version: 0,
              flags: 0,
              entry_count: 1,
              entry_list: [
                %{
                  first_chunk: 1,
                  samples_per_chunk: track.sample_count,
                  sample_description_index: 1
                }
              ]
            }
          },
          stsz: %{
            fields: %{
              version: 0,
              flags: 0,
              sample_size: 0,
              sample_count: track.sample_count,
              entry_list: entry_sizes
            }
          },
          stco: %{
            fields: %{
              version: 0,
              flags: 0,
              entry_count: 1,
              entry_list: [
                %{
                  chunk_offset: chunk_offset
                }
              ]
            }
          }
        ],
        fields: %{}
      }
    ]
  end

  defp sample_description(%Track{content: %AVC1{} = avc1} = config) do
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
          height: config.height,
          horizresolution: {0, 0},
          num_of_entries: 1,
          version: 0,
          vertresolution: {0, 0},
          width: config.width
        }
      }
    ]
  end

  defp sample_description(%Track{content: %AAC{} = aac}) do
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
end
