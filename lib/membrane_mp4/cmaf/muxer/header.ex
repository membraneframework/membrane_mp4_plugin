defmodule Membrane.MP4.CMAF.Muxer.Header do
  @moduledoc false
  alias Membrane.MP4.{CommonBox, Container}

  @spec serialize(%{
          timescale: integer,
          width: :integer,
          height: :integer,
          content: struct
        }) :: binary
  def serialize(config) do
    cmaf_config =
      config |> Map.merge(%{duration: 0, common_duration: 0, common_timescale: 1, track_id: 1})

    ftyp = CommonBox.file_type()
    mvhd = cmaf_config |> Map.put(:next_track_id, 2) |> CommonBox.movie_header()

    (ftyp ++
       [
         moov: %{
           children: mvhd ++ track(cmaf_config) ++ mvex(),
           fields: %{}
         }
       ])
    |> Container.serialize!()
  end

  defp track(config) do
    track_header = CommonBox.track_header(config)
    media_handler_header = CommonBox.media_handler_header(config)
    handler = CommonBox.handler(config)
    media_header = CommonBox.media_header(config)
    sample_description = CommonBox.sample_description(config)

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

  defp mvex() do
    [
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
    ]
  end
end
