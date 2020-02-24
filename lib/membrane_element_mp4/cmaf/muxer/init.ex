defmodule Membrane.Element.MP4.CMAF.Muxer.Init do
  alias Membrane.Element.MP4.Schema
  alias Membrane.Caps.MP4.Payload.{AVC1, AAC}

  @spec serialize(%{
          timescale: integer,
          width: :integer,
          height: :integer,
          content_type: atom,
          type_specific: any
        }) ::
          binary
  def serialize(config) do
    sample_description = sample_description(config)

    [
      ftyp: %{
        children: [],
        fields: %{
          compatible_brands: ["iso6", "mp41"],
          major_brand: "iso5",
          major_brand_version: 512
        }
      },
      moov: %{
        children: [
          mvhd: %{
            children: [],
            fields: %{
              creation_time: 0,
              duration: 0,
              flags: 0,
              matrix_value_A: {0, 1},
              matrix_value_B: {0, 0},
              matrix_value_C: {0, 0},
              matrix_value_D: {0, 1},
              matrix_value_U: {0, 0},
              matrix_value_V: {0, 0},
              matrix_value_W: {0, 1},
              matrix_value_X: {0, 0},
              matrix_value_Y: {0, 0},
              modification_time: 0,
              next_track_id: 2,
              quicktime_current_time: 0,
              quicktime_poster_time: 0,
              quicktime_preview_duration: 0,
              quicktime_preview_time: 0,
              quicktime_selection_duration: 0,
              quicktime_selection_time: 0,
              rate: {0, 1},
              timescale: 1,
              version: 0,
              volume: {0, 1}
            }
          },
          trak: %{
            children: [
              tkhd: %{
                children: [],
                fields: %{
                  alternate_group: 0,
                  creation_time: 0,
                  duration: 0,
                  flags: 3,
                  height: {config.height, 0},
                  layer: 0,
                  matrix_value_A: {1, 0},
                  matrix_value_B: {0, 0},
                  matrix_value_C: {0, 0},
                  matrix_value_D: {1, 0},
                  matrix_value_U: {0, 0},
                  matrix_value_V: {0, 0},
                  matrix_value_W: {16384, 0},
                  matrix_value_X: {0, 0},
                  matrix_value_Y: {0, 0},
                  modification_time: 0,
                  track_id: 1,
                  version: 0,
                  volume: {0, 1},
                  width: {config.width, 0}
                }
              },
              mdia: %{
                children: [
                  mdhd: %{
                    children: [],
                    fields: %{
                      creation_time: 0,
                      duration: 0,
                      flags: 0,
                      language: 21956,
                      modification_time: 0,
                      timescale: config.timescale,
                      version: 0
                    }
                  },
                  hdlr: handler(config),
                  minf: %{
                    children:
                      media_header(config) ++
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
                          },
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
                                fields: %{version: 0, flags: 0, entry_count: 0, entry_list: []}
                              },
                              stsc: %{
                                fields: %{version: 0, flags: 0, entry_count: 0, entry_list: []}
                              },
                              stsz: %{
                                fields: %{
                                  version: 0,
                                  flags: 0,
                                  sample_size: 0,
                                  entry_count: 0,
                                  entry_list: []
                                }
                              },
                              stco: %{
                                fields: %{version: 0, flags: 0, entry_count: 0, entry_list: []}
                              }
                            ],
                            fields: %{}
                          }
                        ],
                    fields: %{}
                  }
                ],
                fields: %{}
              }
            ],
            fields: %{}
          },
          mvex: %{
            children: [
              trex: %{
                fields: %{
                  version: 0,
                  flags: 0,
                  track_id: 1,
                  default_sample_description_index: 1,
                  default_sample_duration: 0,
                  default_sample_size: 0,
                  default_sample_flags: 0
                }
              }
            ]
          }
        ],
        fields: %{}
      }
    ]
    |> Schema.serialize()
  end

  defp sample_description(%{content: %AVC1{} = avc1} = config) do
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

  defp sample_description(%{content: %AAC{} = aac}) do
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
          sample_rate: {0, aac.sample_rate}
        }
      }
    ]
  end

  defp handler(%{content: %AVC1{}}) do
    %{
      children: [],
      fields: %{
        flags: 0,
        handler_type: "vide",
        name: "VideoHandler",
        version: 0
      }
    }
  end

  defp handler(%{content: %AAC{}}) do
    %{
      children: [],
      fields: %{
        flags: 0,
        handler_type: "soun",
        name: "SoundHandler",
        version: 0
      }
    }
  end

  defp media_header(%{content: %AVC1{}}) do
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

  defp media_header(%{content: %AAC{}}) do
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
end
