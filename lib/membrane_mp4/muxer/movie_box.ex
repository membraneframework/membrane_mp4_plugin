defmodule Membrane.MP4.Muxer.MovieBox do
  @moduledoc false
  alias Membrane.Time

  alias Membrane.MP4.{CommonBox, Container}

  @type track :: %{
          config: %{
            timescale: integer,
            width: :integer,
            height: :integer,
            content: struct
          },
          sample_count: integer,
          buffers: Qex.t(%Membrane.Buffer{})
        }

  @spec serialize(%{tracks: [track], timescale: integer}) :: binary
  def serialize(config) do
    n_tracks = length(config.tracks)

    tracks =
      config.tracks
      |> Enum.zip(1..n_tracks)
      |> Enum.map(fn {track, id} ->
        use Ratio

        duration =
          if track.sample_count > 1 do
            # fixme: workaround here, cause we don't know the duration of last sample
            first_timestamp = Qex.first!(track.buffers).metadata.timestamp
            last_timestamp = Qex.last!(track.buffers).metadata.timestamp

            div(last_timestamp - first_timestamp, track.sample_count) * (track.sample_count + 1)
          else
            0
          end

        track
        |> Map.update!(
          :config,
          &Map.merge(&1, %{
            track_id: id,
            duration: timescalify(duration, &1.timescale),
            common_duration: timescalify(duration, config.timescale)
          })
        )
      end)

    longest_track = tracks |> Enum.max_by(& &1.config.common_duration)

    mvhd =
      %{
        common_timescale: config.timescale,
        common_duration: longest_track.config.common_duration,
        next_track_id: n_tracks + 1
      }
      |> CommonBox.movie_header()

    traks = Enum.flat_map(tracks, &track_box/1)

    [
      moov: %{
        children: mvhd ++ traks,
        fields: %{}
      }
    ]
    |> Container.serialize!()
  end

  defp track_box(%{config: config, sample_count: sample_count, buffers: buffers}) do
    ftyp_size = CommonBox.file_type() |> Container.serialize!() |> byte_size()
    mdat_header_size = [mdat: %{content: <<>>}] |> Container.serialize!() |> byte_size()
    chunk_offset = ftyp_size + mdat_header_size

    track_header = CommonBox.track_header(config)
    sample_description = CommonBox.sample_description(config)
    media_handler_header = CommonBox.media_handler_header(config)
    handler = CommonBox.handler(config)
    media_header = CommonBox.media_header(config)

    sample_delta = div(config.duration, sample_count)
    entry_sizes = Enum.map(buffers, &%{entry_size: byte_size(&1.payload)})

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
                                          chunk_offset: chunk_offset
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

  defp timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end
end
