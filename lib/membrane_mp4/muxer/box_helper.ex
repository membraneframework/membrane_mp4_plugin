defmodule Membrane.MP4.Muxer.BoxHelper do
  @moduledoc false
  alias Membrane.Time

  alias Membrane.MP4.Container
  alias Membrane.MP4.Payload.{AAC, AVC1}

  @type track_info :: %{
          timescale: integer,
          width: :integer,
          height: :integer,
          content: struct,
          first_timestamp: integer,
          last_timestamp: integer,
          payload_sizes: [integer]
        }

  @type full_track_info ::
          track_info
          | %{
              duration: integer,
              common_duration: integer,
              sample_count: integer
            }

  @ftyp [
    ftyp: %{
      children: [],
      fields: %{
        compatible_brands: ["isom", "iso2", "avc1", "mp41"],
        major_brand: "isom",
        major_brand_version: 512
      }
    }
  ]

  @ftyp_size @ftyp |> Container.serialize!() |> byte_size()

  @mdat_header_size 8

  @common_timescale 1000

  @spec file_type_box :: keyword()
  def file_type_box(), do: @ftyp

  @spec media_data_box([%Membrane.Buffer{}]) :: keyword()
  def media_data_box(buffers) do
    [
      mdat: %{
        content: buffers |> Enum.map(& &1.payload) |> Enum.join()
      }
    ]
  end

  @spec movie_box([track_info]) :: keyword()
  def movie_box(tracks) do
    full_tracks = tracks |> Enum.map(&make_full_track/1)

    max_common_duration =
      full_tracks |> Enum.max_by(& &1.common_duration) |> Map.fetch!(:common_duration)

    next_track_id = length(full_tracks) + 1

    mvhd = movie_header(max_common_duration, next_track_id)

    traks = Enum.flat_map(full_tracks, &track_box/1)

    [
      moov: %{
        children: mvhd ++ traks,
        fields: %{}
      }
    ]
  end

  @spec movie_header(integer, integer) :: keyword()
  defp movie_header(common_duration, next_track_id) do
    [
      mvhd: %{
        children: [],
        fields: %{
          creation_time: 0,
          duration: common_duration,
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
          timescale: @common_timescale,
          version: 0,
          volume: {1, 0}
        }
      }
    ]
  end

  @spec make_full_track(track_info) :: full_track_info
  defp make_full_track(track) do
    use Ratio
    # fixme: workaround here, cause we don't know the duration of last sample
    duration = track.last_timestamp - track.first_timestamp
    sample_count = length(track.payload_sizes)
    avg_duration = div(duration, sample_count)
    full_duration = duration + avg_duration

    track
    |> Map.update!(:last_timestamp, &(&1 + avg_duration))
    |> Map.merge(%{
      duration: timescalify(full_duration, track.timescale),
      common_duration: timescalify(full_duration, @common_timescale),
      sample_count: sample_count
    })
  end

  @spec track_box(full_track_info) :: keyword()
  defp track_box(track) do
    sample_description = sample_description(track)
    sample_count = track.sample_count
    sample_delta = div(track.duration, sample_count)
    entry_sizes = Enum.map(track.payload_sizes, &%{entry_size: &1})

    [
      trak: %{
        children: [
          tkhd: %{
            children: [],
            fields: %{
              alternate_group: 0,
              creation_time: 0,
              duration: track.common_duration,
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
              track_id: 1,
              version: 0,
              volume:
                case track.content do
                  %AVC1{} -> {0, 0}
                  %AAC{} -> {1, 0}
                end,
              width: {track.width, 0}
            }
          },
          mdia: %{
            children: [
              mdhd: %{
                children: [],
                fields: %{
                  creation_time: 0,
                  duration: track.duration,
                  flags: 0,
                  language: 21956,
                  modification_time: 0,
                  timescale: track.timescale,
                  version: 0
                }
              },
              hdlr: handler(track),
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
                            fields: %{
                              version: 0,
                              flags: 0,
                              entry_count: 1,
                              entry_list: [
                                %{
                                  sample_count: sample_count,
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
                                  samples_per_chunk: sample_count,
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
                              sample_count: sample_count,
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
                                  chunk_offset: @ftyp_size + @mdat_header_size
                                }
                              ]
                            }
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
      }
    ]
  end

  # fixme: functions below are identical to ones for cmaf muxer, extract to common module

  defp timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
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
          sample_rate: {aac.sample_rate, 0}
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
