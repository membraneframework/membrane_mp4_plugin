defmodule Membrane.MP4.Container.SchemaDef do
  @moduledoc false

  defp full_box(version: version) do
    version = if is_integer(version), do: [version], else: version

    [
      version: {:uint8, [store: :version, in: version]},
      flags: {:uint24, store: :fo_flags}
    ]
  end

  defp visual_sample_entry(type) do
    fields =
      full_box(version: 0) ++
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

    pasp = [
      fields: [
        h_spacing: :uint32,
        v_spacing: :uint32
      ]
    ]

    [fields: fields] ++ [{type, black_box?: true}] ++ [pasp: pasp]
  end

  def schema_def() do
    [
      ftyp: [
        fields: [
          major_brand: :str32,
          major_brand_version: :uint32,
          compatible_brands: {:list, :str32}
        ]
      ],
      moov: [
        mvhd: [
          fields:
            full_box(version: 0..1) ++
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
            fields:
              full_box(version: 0..1) ++
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
              fields:
                full_box(version: 0..1) ++
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
              fields:
                full_box(version: 0) ++
                  [
                    reserved: <<0::32>>,
                    handler_type: :str32,
                    reserved: <<0::96>>,
                    name: :str
                  ]
            ],
            minf: [
              vmhd: [
                fields:
                  full_box(version: 0) ++
                    [
                      graphics_mode: :uint16,
                      opcolor: :uint48
                    ]
              ],
              smhd: [
                fields:
                  full_box(version: 0) ++
                    [
                      balance: :fp8d8,
                      reserved: <<0::16>>
                    ]
              ],
              dinf: [
                dref: [
                  fields:
                    full_box(version: 0) ++
                      [
                        entry_count: :uint32
                      ],
                  url: [
                    fields: full_box(version: 0)
                  ]
                ]
              ],
              stbl: [
                stsd: [
                  fields:
                    full_box(version: 0) ++
                      [
                        entry_count: :uint32
                      ],
                  avc1: visual_sample_entry(:avcC),
                  avc3: visual_sample_entry(:avcC),
                  hvc1: visual_sample_entry(:hvcC),
                  hev1: visual_sample_entry(:hvcC),
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
                      fields:
                        full_box(version: 0) ++
                          [
                            elementary_stream_descriptor: :bin
                          ]
                    ]
                  ],
                  Opus: [
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
                      fields: [
                        version: {:uint8, in: [0]},
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
                  fields:
                    full_box(version: 0) ++
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
                  fields:
                    full_box(version: 0) ++
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
                  fields:
                    full_box(version: 0) ++
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
                  fields:
                    full_box(version: 0) ++
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
                  fields:
                    full_box(version: 0) ++
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
                  fields:
                    full_box(version: 0) ++
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
                  fields:
                    full_box(version: 0) ++
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
            fields:
              full_box(version: 0) ++
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
        fields:
          full_box(version: 1) ++
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
          fields:
            full_box(version: 0) ++
              [
                sequence_number: :uint32
              ]
        ],
        traf: [
          tfhd: [
            fields:
              full_box(version: 0) ++
                [
                  track_id: :uint32,
                  default_sample_duration: :uint32,
                  default_sample_size: :uint32,
                  default_sample_flags: :uint32
                ]
          ],
          tfdt: [
            fields:
              full_box(version: 1) ++
                [
                  base_media_decode_time: :uint64
                ]
          ],
          trun: [
            fields:
              full_box(version: 0) ++
                [
                  sample_count: :uint32,
                  data_offset: :int32,
                  samples:
                    {:list,
                     [
                       sample_duration: :uint32,
                       sample_size: :uint32,
                       sample_flags: :bin32,
                       sample_composition_offset: {:uint32, when: {:fo_flags, mask: 0x800}}
                     ]}
                ]
          ]
        ]
      ],
      mdat: [
        black_box?: true
      ]
    ]
  end

  @spec parse(Schema.schema_def_t()) :: Schema.t()
  def parse(schema) do
    Map.new(schema, &parse_box/1)
  end

  defp parse_box({name, schema}) do
    schema =
      if schema[:black_box?] do
        Map.new(schema)
      else
        {schema, children} = schema |> Keyword.split([:version, :fields, :black_box?])

        schema
        |> Map.new()
        |> Map.merge(%{black_box?: false, children: parse(children)})
        |> Map.update(:fields, [], &parse_fields/1)
        |> case do
          %{version: _version, fields: fields} when not is_map_key(fields, :version) ->
            raise "Version requirement provided for box #{name}, but field version is absent"

          %{version: version} = schema when is_integer(version) ->
            %{schema | version: [version]}

          schema ->
            schema
        end
      end

    {name, schema}
  end

  defp parse_fields(fields) do
    Enum.map(fields, &parse_field/1)
  end

  defp parse_field({name, subfields}) when is_list(subfields) do
    {name, parse_fields(subfields)}
  end

  defp parse_field({:reserved, _reserved} = field), do: field

  defp parse_field({name, type}) when is_atom(type) do
    type =
      case Atom.to_string(type) do
        "int" <> s ->
          {:int, String.to_integer(s)}

        "uint" <> s ->
          {:uint, String.to_integer(s)}

        "bin" ->
          :bin

        "bin" <> s ->
          {:bin, String.to_integer(s)}

        "str" ->
          :str

        "str" <> s ->
          {:str, String.to_integer(s)}

        "fp" <> rest ->
          {s1, "d" <> s2} = Integer.parse(rest)
          {:fp, s1, String.to_integer(s2)}
      end

    {name, type}
  end

  defp parse_field({name, {:list, type}}) do
    {name, type} = parse_field({name, type})
    {name, {:list, type}}
  end

  defp parse_field({name, {type, opts}}) when is_atom(name) and is_list(opts) do
    Keyword.validate!(opts, [:store, :when, :in])
    {name, type} = parse_field({name, type})
    type = {type, Map.new(opts)}
    {name, type}
  end
end
