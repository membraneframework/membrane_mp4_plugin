defmodule Membrane.MP4.Container.Schema.Default do
  # Moduledoc is below the schema definition
  alias Membrane.MP4.Container.Schema

  @full_box [
    version: {:uint8, store: :version},
    flags: {:uint24, store: :fo_flags}
  ]

  @visual_sample_entry @full_box ++
                         [
                           num_of_entries: :uint32,
                           reserved: <<0::128>>,
                           width: :uint16,
                           height: :uint16,
                           horizresolution: :fp16d16,
                           vertresolution: :fp16d16,
                           reserved: <<0::32>>,
                           frame_count: :uint16,
                           compressor_name: :str256,
                           depth: :uint16,
                           reserved: <<-1::16-integer>>
                         ]

  @avc_schema [
    version: 0,
    fields: @visual_sample_entry,
    avcC: [
      black_box?: true
    ],
    pasp: [
      fields: [
        h_spacing: :uint32,
        v_spacing: :uint32
      ]
    ]
  ]

  @hevc_schema [
    version: 0,
    fields: @visual_sample_entry,
    hvcC: [
      black_box?: true
    ],
    pasp: [
      fields: [
        h_spacing: :uint32,
        v_spacing: :uint32
      ]
    ]
  ]

  @schema_def ftyp: [
                fields: [
                  major_brand: :str32,
                  major_brand_version: :uint32,
                  compatible_brands: {:list, :str32}
                ]
              ],
              moov: [
                mvhd: [
                  version: 0,
                  fields:
                    @full_box ++
                      [
                        creation_time: {:uint32, when: {:version, value: 0}},
                        creation_time: {:uint64, when: {:version, value: 1}},
                        modification_time: {:uint32, when: {:version, value: 0}},
                        modification_time: {:uint64, when: {:version, value: 1}},
                        timescale: :uint32,
                        duration: {:uint32, when: {:version, value: 0}},
                        duration: {:uint64, when: {:version, value: 1}},
                        rate: :fp16d16,
                        volume: :fp8d8,
                        reserved: <<0::size(80)>>,
                        matrix_value_A: :fp16d16,
                        matrix_value_B: :fp16d16,
                        matrix_value_U: :fp2d30,
                        matrix_value_C: :fp16d16,
                        matrix_value_D: :fp16d16,
                        matrix_value_V: :fp2d30,
                        matrix_value_X: :fp16d16,
                        matrix_value_Y: :fp16d16,
                        matrix_value_W: :fp2d30,
                        quicktime_preview_time: :uint32,
                        quicktime_preview_duration: :uint32,
                        quicktime_poster_time: :uint32,
                        quicktime_selection_time: :uint32,
                        quicktime_selection_duration: :uint32,
                        quicktime_current_time: :uint32,
                        next_track_id: :uint32
                      ]
                ],
                trak: [
                  tkhd: [
                    version: 0,
                    fields:
                      @full_box ++
                        [
                          creation_time: {:uint32, when: {:version, value: 0}},
                          creation_time: {:uint64, when: {:version, value: 1}},
                          modification_time: {:uint32, when: {:version, value: 0}},
                          modification_time: {:uint64, when: {:version, value: 1}},
                          track_id: :uint32,
                          reserved: <<0::32>>,
                          duration: {:uint32, when: {:version, value: 0}},
                          duration: {:uint64, when: {:version, value: 1}},
                          reserved: <<0::64>>,
                          layer: :int16,
                          alternate_group: :int16,
                          volume: :fp8d8,
                          reserved: <<0::16>>,
                          matrix_value_A: :fp16d16,
                          matrix_value_B: :fp16d16,
                          matrix_value_U: :fp2d30,
                          matrix_value_C: :fp16d16,
                          matrix_value_D: :fp16d16,
                          matrix_value_V: :fp2d30,
                          matrix_value_X: :fp16d16,
                          matrix_value_Y: :fp16d16,
                          matrix_value_W: :fp2d30,
                          width: :fp16d16,
                          height: :fp16d16
                        ]
                  ],
                  mdia: [
                    mdhd: [
                      version: 0,
                      fields:
                        @full_box ++
                          [
                            creation_time: {:uint32, when: {:version, value: 0}},
                            creation_time: {:uint64, when: {:version, value: 1}},
                            modification_time: {:uint32, when: {:version, value: 0}},
                            modification_time: {:uint64, when: {:version, value: 1}},
                            timescale: :uint32,
                            duration: {:uint32, when: {:version, value: 0}},
                            duration: {:uint64, when: {:version, value: 1}},
                            reserved: <<0::1>>,
                            language: :uint15,
                            reserved: <<0::16>>
                          ]
                    ],
                    hdlr: [
                      version: 0,
                      fields:
                        @full_box ++
                          [
                            reserved: <<0::32>>,
                            handler_type: :str32,
                            reserved: <<0::96>>,
                            name: :str
                          ]
                    ],
                    minf: [
                      vmhd: [
                        version: 0,
                        fields:
                          @full_box ++
                            [
                              graphics_mode: :uint16,
                              opcolor: :uint48
                            ]
                      ],
                      smhd: [
                        version: 0,
                        fields:
                          @full_box ++
                            [
                              balance: :fp8d8,
                              reserved: <<0::16>>
                            ]
                      ],
                      dinf: [
                        dref: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32
                              ],
                          url: [
                            version: 0,
                            fields: @full_box
                          ]
                        ]
                      ],
                      stbl: [
                        stsd: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32
                              ],
                          avc1: @avc_schema,
                          avc3: @avc_schema,
                          hvc1: @hevc_schema,
                          hev1: @hevc_schema,
                          mp4a: [
                            fields: [
                              reserved: <<0::6*8>>,
                              data_reference_index: :uint16,
                              encoding_version: :uint16,
                              encoding_revision: :uint16,
                              encoding_vendor: :uint32,
                              channel_count: :uint16,
                              sample_size: :uint16,
                              compression_id: :uint16,
                              packet_size: :uint16,
                              sample_rate: :fp16d16
                            ],
                            esds: [
                              version: 0,
                              fields:
                                @full_box ++
                                  [
                                    elementary_stream_descriptor: :bin
                                  ]
                            ]
                          ],
                          Opus: [
                            version: 0,
                            fields: [
                              reserved: <<0::6*8>>,
                              data_reference_index: :uint16,
                              reserved: <<0::2*32>>,
                              channel_count: :uint16,
                              sample_size: :uint16,
                              # pre_defined
                              reserved: <<0::16>>,
                              reserved: <<0::16>>,
                              sample_rate: :uint32
                            ],
                            dOps: [
                              version: 0,
                              fields: [
                                version: :uint8,
                                output_channel_count: :uint8,
                                pre_skip: :uint16,
                                input_sample_rate: :uint32,
                                output_gain: :int16,
                                channel_mapping_family: :uint8
                              ]
                            ]
                          ]
                        ],
                        stts: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     sample_count: :uint32,
                                     sample_delta: :uint32
                                   ]}
                              ]
                        ],
                        stss: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     sample_number: :uint32
                                   ]}
                              ]
                        ],
                        ctts: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     sample_count: :uint32,
                                     sample_composition_offset:
                                       {:uint32, when: {:version, value: 0}},
                                     sample_composition_offset:
                                       {:int32, when: {:version, value: 1}}
                                   ]}
                              ]
                        ],
                        stsc: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     first_chunk: :uint32,
                                     samples_per_chunk: :uint32,
                                     sample_description_index: :uint32
                                   ]}
                              ]
                        ],
                        stsz: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                sample_size: {:uint32, store: :sample_size},
                                sample_count: :uint32,
                                entry_list: {
                                  {:list,
                                   [
                                     entry_size: :uint32
                                   ]},
                                  when: {:sample_size, value: 0}
                                }
                              ]
                        ],
                        stco: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     chunk_offset: :uint32
                                   ]}
                              ]
                        ],
                        co64: [
                          version: 0,
                          fields:
                            @full_box ++
                              [
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     chunk_offset: :uint64
                                   ]}
                              ]
                        ]
                      ]
                    ]
                  ]
                ],
                mvex: [
                  trex: [
                    version: 0,
                    fields:
                      @full_box ++
                        [
                          track_id: :uint32,
                          default_sample_description_index: :uint32,
                          default_sample_duration: :uint32,
                          default_sample_size: :uint32,
                          default_sample_flags: :uint32
                        ]
                  ]
                ]
              ],
              styp: [
                fields: [
                  major_brand: :str32,
                  major_brand_version: :uint32,
                  compatible_brands: {:list, :str32}
                ]
              ],
              sidx: [
                version: 0,
                fields:
                  @full_box ++
                    [
                      reference_id: :uint32,
                      timescale: :uint32,
                      earliest_presentation_time: {:uint32, when: {:version, value: 0}},
                      earliest_presentation_time: {:uint64, when: {:version, value: 1}},
                      first_offset: {:uint32, when: {:version, value: 0}},
                      first_offset: {:uint64, when: {:version, value: 1}},
                      reserved: <<0::16-integer>>,
                      reference_count: :uint16,
                      reference_list:
                        {:list,
                         [
                           reference_type: :bin1,
                           referenced_size: :uint31,
                           subsegment_duration: :uint32,
                           starts_with_sap: :bin1,
                           sap_type: :uint3,
                           sap_delta_time: :uint28
                         ]}
                    ]
              ],
              moof: [
                mfhd: [
                  version: 0,
                  fields:
                    @full_box ++
                      [
                        sequence_number: :uint32
                      ]
                ],
                traf: [
                  tfhd: [
                    version: 0,
                    fields:
                      @full_box ++
                        [
                          track_id: :uint32,
                          base_data_offset: {:uint64, when: {:fo_flags, mask: 0x00001}},
                          sample_description_index: {:uint32, when: {:fo_flags, mask: 0x00002}},
                          default_sample_duration: {:uint32, when: {:fo_flags, mask: 0x000008}},
                          default_sample_size: {:uint32, when: {:fo_flags, mask: 0x000010}},
                          default_sample_flags: {:uint32, when: {:fo_flags, mask: 0x000020}}
                        ]
                  ],
                  tfdt: [
                    version: 1,
                    fields:
                      @full_box ++
                        [
                          base_media_decode_time: {:uint32, when: {:version, value: 0}},
                          base_media_decode_time: {:uint64, when: {:version, value: 1}}
                        ]
                  ],
                  trun: [
                    version: 0,
                    fields:
                      @full_box ++
                        [
                          sample_count: {:uint32, store: :sample_count},
                          data_offset: {:int32, when: {:fo_flags, mask: 0x000001}},
                          first_sample_flags: {:bin32, when: {:fo_flags, mask: 0x000004}},
                          samples:
                            {:list,
                             [
                               sample_duration: {:uint32, when: {:fo_flags, mask: 0x000100}},
                               sample_size: {:uint32, when: {:fo_flags, mask: 0x000200}},
                               sample_flags: {:bin32, when: {:fo_flags, mask: 0x000400}},
                               sample_composition_time_offset:
                                 {:uint32, when: {:fo_flags, mask: 0x000800}}
                             ], length: :sample_count}
                        ]
                  ],
                  trun: [
                    version: 1,
                    fields:
                      @full_box ++
                        [
                          sample_count: {:uint32, store: :sample_count},
                          data_offset: {:int32, when: {:fo_flags, mask: 0x000001}},
                          first_sample_flags: {:bin32, when: {:fo_flags, mask: 0x000004}},
                          samples:
                            {:list,
                             [
                               sample_duration: {:uint32, when: {:fo_flags, mask: 0x000100}},
                               sample_size: {:uint32, when: {:fo_flags, mask: 0x000200}},
                               sample_flags: {:bin32, when: {:fo_flags, mask: 0x000400}},
                               sample_composition_time_offset:
                                 {:int32, when: {:fo_flags, mask: 0x000800}}
                             ], length: :sample_count}
                        ]
                  ]
                ]
              ],
              emsg: [
                version: 0,
                fields:
                  @full_box ++
                    [
                      scheme_id_uri: :str,
                      value: :str,
                      timescale: :uint32,
                      presentation_time_delta: {:uint32, when: {:version, value: 0}},
                      presentation_time: {:uint64, when: {:version, value: 1}},
                      event_duration: :uint32,
                      id: :uint32,
                      message_data: :bin
                    ]
              ],
              mdat: [
                black_box?: true
              ],
              free: [
                black_box?: true
              ],
              skip: [
                black_box?: true
              ]

  # credo:disable-for-next-line
  @moduledoc """
  MP4 structure schema used for parsing and serialization.

  The schema definition is the following:
  ```
  #{inspect(@schema_def, pretty: true)}
  ```

  Useful resources:
  - https://www.iso.org/standard/79110.html
  - https://www.iso.org/standard/61988.html
  - https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap2/qtff2.html
  - https://github.com/DicomJ/mpeg-isobase/tree/eb09f82ff6e160715dcb34b2bf473330c7695d3b
  """
  @schema Schema.parse(@schema_def)

  # MapSet.t/1 incorrectly exposes MapSet.internal/1 as opaque in specs; fixed in Elixir v1.20
  @dialyzer {:no_contracts, schema: 0}
  @spec schema() :: Schema.t()
  def schema(), do: @schema

  @spec schema_def() :: Schema.schema_def_t()
  def schema_def(), do: @schema_def
end
