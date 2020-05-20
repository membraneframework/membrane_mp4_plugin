defmodule Membrane.MP4.Container.Schema do
  # TODO support different box versions (via conditional fields?)
  # TODO support lists with custom length

  # resources:
  # https://www.iso.org/standard/79110.html
  # https://www.iso.org/standard/61988.html
  # https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap2/qtff2.html#//apple_ref/doc/uid/TP40000939-CH204-SW1
  # https://github.com/DicomJ/mpeg-isobase/tree/eb09f82ff6e160715dcb34b2bf473330c7695d3b

  @full_box [
    version: :uint8,
    flags: :uint24
  ]

  @raw_schema ftyp: [
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
                        creation_time: :uint32,
                        modification_time: :uint32,
                        timescale: :uint32,
                        duration: :uint32,
                        rate: :fp16p16,
                        volume: :fp8p8,
                        reserved: <<0::size(80)>>,
                        matrix_value_A: :fp16p16,
                        matrix_value_B: :fp16p16,
                        matrix_value_U: :fp2p30,
                        matrix_value_C: :fp16p16,
                        matrix_value_D: :fp16p16,
                        matrix_value_V: :fp2p30,
                        matrix_value_X: :fp16p16,
                        matrix_value_Y: :fp16p16,
                        matrix_value_W: :fp2p30,
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
                          creation_time: :uint32,
                          modification_time: :uint32,
                          track_id: :uint32,
                          reserved: <<0::32>>,
                          duration: :uint32,
                          reserved: <<0::64>>,
                          layer: :int16,
                          alternate_group: :int16,
                          volume: :fp8p8,
                          reserved: <<0::16>>,
                          matrix_value_A: :fp16p16,
                          matrix_value_B: :fp16p16,
                          matrix_value_U: :fp2p30,
                          matrix_value_C: :fp16p16,
                          matrix_value_D: :fp16p16,
                          matrix_value_V: :fp2p30,
                          matrix_value_X: :fp16p16,
                          matrix_value_Y: :fp16p16,
                          matrix_value_W: :fp2p30,
                          width: :fp16p16,
                          height: :fp16p16
                        ]
                  ],
                  mdia: [
                    mdhd: [
                      version: 0,
                      fields:
                        @full_box ++
                          [
                            creation_time: :uint32,
                            modification_time: :uint32,
                            timescale: :uint32,
                            duration: :uint32,
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
                              balance: :fp8p8,
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
                          avc1: [
                            version: 0,
                            fields:
                              @full_box ++
                                [
                                  num_of_entries: :uint32,
                                  reserved: <<0::128>>,
                                  width: :uint16,
                                  height: :uint16,
                                  horizresolution: :fp16p16,
                                  vertresolution: :fp16p16,
                                  reserved: <<0::32>>,
                                  frame_count: :uint16,
                                  compressor_name: :str256,
                                  depth: :uint16,
                                  reserved: <<-1::16-integer>>
                                ],
                            avcC: [
                              black_box?: true
                            ],
                            pasp: [
                              fields: [
                                h_spacing: :uint32,
                                v_spacing: :uint32
                              ]
                            ]
                          ],
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
                              sample_rate: :fp16p16
                            ],
                            esds: [
                              version: 0,
                              fields:
                                @full_box ++
                                  [
                                    elementary_stream_descriptor: :bin
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
                                sample_size: :uint32,
                                entry_count: :uint32,
                                entry_list:
                                  {:list,
                                   [
                                     entry_size: :uint32
                                   ]}
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
                version: 1,
                fields:
                  @full_box ++
                    [
                      reference_id: :uint32,
                      timescale: :uint32,
                      earliest_presentation_time: :uint64,
                      first_offset: :uint64,
                      reserved: <<0::16-integer>>,
                      reference_count: :uint16,
                      # reference_list: [
                      #   [
                      #     reference_type: :bin1,
                      #     referenced_size: :uint31,
                      #     subsegment_duration: :uint32,
                      #     starts_with_sap: :bin1,
                      #     sap_type: :uint3,
                      #     sap_delta_time: :uint28
                      #   ],
                      #   length: :reference_count
                      # ]
                      reference_type: :bin1,
                      # from the beginning of moof to the end
                      referenced_size: :uint31,
                      subsegment_duration: :uint32,
                      starts_with_sap: :bin1,
                      sap_type: :uint3,
                      sap_delta_time: :uint28
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
                          default_sample_duration: :uint32,
                          default_sample_size: :uint32,
                          default_sample_flags: :uint32
                        ]
                  ],
                  tfdt: [
                    version: 1,
                    fields:
                      @full_box ++
                        [
                          base_media_decode_time: :uint64
                        ]
                  ],
                  trun: [
                    version: 0,
                    fields:
                      @full_box ++
                        [
                          sample_count: :uint32,
                          data_offset: :int32,
                          samples:
                            {:list,
                             [
                               sample_duration: :uint32,
                               sample_size: :uint32,
                               sample_flags: :bin32
                               # sample_flags: :uint32
                               # sample_offset: :uint32
                             ]}
                        ]
                  ]
                ]
              ],
              mdat: [
                black_box?: true
              ]

  @schema __MODULE__.Parser.parse(@raw_schema)

  def schema(), do: @schema
end
