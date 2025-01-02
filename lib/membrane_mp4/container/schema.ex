defmodule Membrane.MP4.Container.Schema do
  @moduledoc """
  MP4 structure schema used for parsing and serialization.

  Useful resources:
  - https://www.iso.org/standard/79110.html
  - https://www.iso.org/standard/61988.html
  - https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap2/qtff2.html
  - https://github.com/DicomJ/mpeg-isobase/tree/eb09f82ff6e160715dcb34b2bf473330c7695d3b
  """

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
                                     sample_composition_offset: :uint32
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
                      # TODO: make a list once list length is supported
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
                          data_offset: {:int32, when: {:fo_flags, mask: 0x000001}},
                          first_sample_flags: {:bin32, when: {:fo_flags, mask: 0x000004}},
                          samples:
                            {:list,
                             [
                               sample_duration: {:uint32, when: {:fo_flags, mask: 0x000100}},
                               sample_size: {:uint32, when: {:fo_flags, mask: 0x000200}},
                               sample_flags: {:bin32, when: {:fo_flags, mask: 0x000400}},
                               sample_composition_offset: 
                                 {:uint32, when: {:fo_flags, mask: 0x000800}}
                             ]}
                        ]
                  ],
        #trun: [
        #version: 1,
        #fields:
        #@full_box ++
        #[
        #sample_count: :uint32,
        #data_offset: {:int32, when: {:fo_flags, mask: 0x000001}},
        #first_sample_flags: {:bin32, when: {:fo_flags, mask: 0x000004}},
        #samples:
        #{:list,
        #[
        #sample_duration: {:uint32, when: {:fo_flags, mask: 0x000100}},
        #sample_size: {:uint32, when: {:fo_flags, mask: 0x000200}},
        #sample_flags: {:bin32, when: {:fo_flags, mask: 0x000404}},
        #sample_composition_offset:
        #{:int32, when: {:fo_flags, mask: 0x000800}}
        #]}
        #]
        #]
                ]
              ],
              mdat: [
                black_box?: true
              ]

  @type schema_def_primitive_t :: atom

  @type schema_def_field_t ::
          {:reserved, bitstring}
          | {field_name :: atom,
             schema_def_primitive_t
             | {:list, schema_def_primitive_t | [schema_def_field_t]}
             | [schema_def_field_t]}

  @type schema_def_box_t ::
          {box_name :: atom,
           [{:black_box?, true}]
           | [
               {:version, non_neg_integer}
               | {:fields, [schema_def_field_t]}
               | schema_def_box_t
             ]}

  @typedoc """
  Type describing the schema definition, that is hardcoded in this module.

  It may be useful for improving the schema definition. The actual schema that
  should be operated on, or, in other words, the parsed schema definition is
  specified by `t:#{inspect(__MODULE__)}.t/0`.

  The schema definition differs from the final schema in the following ways:
    - primitives along with their parameters are specified as atoms, for example
    `:int32` instead of `{:int, 32}`
    - child boxes are nested within their parents directly, instead of residing
    under `:children` key.

  The schema definition is the following:
  ```
  #{inspect(@schema_def, pretty: true)}
  ```
  """
  @type schema_def_t :: [schema_def_box_t]

  @typedoc """
  For fields, the following primitive types are supported:
  - `{:int, bit_size}` - a signed integer
  - `{:uint, bit_size}` - an unsigned integer
  - `:bin` - a binary lasting till the end of a box
  - `{:bin, bit_size}` - a binary of given size
  - `:str` - a string terminated with a null byte
  - `{:str, bit_size}` - a string of given size
  - `{:fp, integer_part_bit_size, fractional_part_bit_size}` - a fixed point number
  """
  @type primitive_t ::
          {:int, bit_size :: non_neg_integer}
          | {:uint, bit_size :: non_neg_integer}
          | :bin
          | {:bin, bit_size :: non_neg_integer}
          | :str
          | {:str, bit_size :: non_neg_integer}
          | {:fp, int_bit_size :: non_neg_integer, frac_bit_size :: non_neg_integer}

  @typedoc """
  A box field type.

  It may contain a primitive, a list or nested fields. Lists last till the end of a box.
  """
  @type field_t ::
          {:reserved, bitstring}
          | {field_name :: atom, primitive_t | {:list, any} | [field_t]}

  @typedoc """
  The schema of MP4 structure.

  An MP4 file consists of boxes, that all have the same header and different internal
  structures. Boxes can be nested with one another.

  Each box has at most 4-letter name and may have the following parameters:
  - `black_box?` - if true, the box content is unspecified and is treated as an opaque
  binary. Defaults to false.
  - `version` - the box version. Versions usually differ by the sizes of particular fields.
  - `fields` - a list of key-value parameters
  - `children` - the nested boxes
  """
  @type t :: %{
          (box_name :: atom) =>
            %{black_box?: true}
            | %{
                black_box?: false,
                version: non_neg_integer,
                fields: [field_t],
                children: map
              }
        }

  @schema __MODULE__.Parser.parse(@schema_def)

  @doc """
  Returns `t:#{inspect(__MODULE__)}.t/0`
  """
  @spec schema() :: t
  def schema(), do: @schema
end
