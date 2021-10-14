defmodule Membrane.MP4.Muxer.MovieBox do
  @moduledoc """
  A module containing a set of utilities for assembling an MPEG-4 movie box.

  The movie box (`moov`) is a top-level box that contains information about
  a presentation as a whole. It consists of:

    * exactly one movie header (`mvhd`)

      Movie header contains media-independent data, such as the number of tracks,
      volume, duration or timescale (presentation-wide).

    * one or more track box (`trak`)

      Track box describes a single track of a presentation. The description includes
      information like its timescale, duration, volume, media-specific data (media
      handlers, sample descriptions) as well as a sample table, which allows media
      players to find and interpret track's data in the media data box.

    * zero or one movie extends box (`mvex`)

      Movie extends box provides information about movie fragment boxes in case when
      media data is fragmented (for example in CMAF).

  For more information about movie box contents, refer to
  [ISO/IEC 14496-12](https://www.iso.org/standard/74428.html).
  """
  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.{Helper, Track}
  alias Membrane.MP4.Payload.{AAC, AVC1}

  @movie_timescale 1000

  defguardp is_audio(track) when {track.height, track.width} == {0, 0}

  @spec assemble([%Track{}], Container.t()) :: Container.t()
  def assemble(tracks, extensions \\ []) do
    tracks =
      1..length(tracks)
      |> Enum.zip(tracks)
      |> Enum.map(fn {id, track} -> Track.finalize(track, id, @movie_timescale) end)

    header = movie_header(tracks)
    track_boxes = Enum.flat_map(tracks, &track_box/1)

    [moov: %{children: header ++ track_boxes ++ extensions, fields: %{}}]
  end

  defp movie_header(tracks) do
    longest_track = Enum.max_by(tracks, & &1.movie_duration)

    [
      mvhd: %{
        children: [],
        fields: %{
          creation_time: 0,
          duration: longest_track.movie_duration,
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
          next_track_id: length(tracks) + 1,
          quicktime_current_time: 0,
          quicktime_poster_time: 0,
          quicktime_preview_duration: 0,
          quicktime_preview_time: 0,
          quicktime_selection_duration: 0,
          quicktime_selection_time: 0,
          rate: {1, 0},
          timescale: @movie_timescale,
          version: 0,
          volume: {1, 0}
        }
      }
    ]
  end

  defp track_box(track) do
    dref =
      {:dref,
       %{
         children: [url: %{children: [], fields: %{flags: 1, version: 0}}],
         fields: %{entry_count: 1, flags: 0, version: 0}
       }}

    dinf = [dinf: %{children: [dref], fields: %{}}]

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
                            dinf ++ sample_table(track),
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
          duration: track.duration,
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
          volume:
            if is_audio(track) do
              {1, 0}
            else
              {0, 0}
            end,
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
          duration: track.duration,
          flags: 0,
          language: 21_956,
          modification_time: 0,
          timescale: track.timescale,
          version: 0
        }
      }
    ]
  end

  defp handler(track) when is_audio(track) do
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

  defp handler(_track) do
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

  defp media_header(track) when is_audio(track) do
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

  defp media_header(_track) do
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

  defp sample_table(track) do
    sample_description = sample_description(track)
    sample_deltas = sample_deltas(track)
    maybe_sample_sync = maybe_sample_sync(track)
    sample_to_chunk = sample_to_chunk(track)
    sample_sizes = sample_sizes(track)
    chunk_offsets = chunk_offsets(track)

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
                entry_count: length(sample_deltas),
                entry_list: sample_deltas
              }
            }
          ] ++
            maybe_sample_sync ++
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
                  sample_count: track.sample_table.sample_count,
                  entry_list: sample_sizes
                }
              },
              stco: %{
                fields: %{
                  version: 0,
                  flags: 0,
                  entry_count: length(chunk_offsets),
                  entry_list: chunk_offsets
                }
              }
            ],
        fields: %{}
      }
    ]
  end

  defp sample_description(%{content: %AVC1{} = avc1} = track) do
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
          height: track.height,
          horizresolution: {0, 0},
          num_of_entries: 1,
          version: 0,
          vertresolution: {0, 0},
          width: track.width
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

  defp sample_deltas(%{timescale: timescale, sample_table: %{decoding_deltas: decoding_deltas}}),
    do:
      Enum.map(decoding_deltas, fn %{sample_count: count, sample_delta: delta} ->
        %{sample_count: count, sample_delta: Helper.timescalify(delta, timescale)}
      end)

  defp maybe_sample_sync(%{sample_table: %{sync_samples: []}}), do: []

  defp maybe_sample_sync(%{sample_table: %{sync_samples: sync_samples}}) do
    sync_samples
    |> Enum.map(&%{sample_number: &1})
    |> then(
      &[
        stss: %{
          fields: %{
            version: 0,
            flags: 0,
            entry_count: length(&1),
            entry_list: &1
          }
        }
      ]
    )
  end

  defp sample_to_chunk(%{sample_table: %{samples_per_chunk: samples_per_chunk}}),
    do:
      Enum.map(
        samples_per_chunk,
        &%{
          first_chunk: &1.first_chunk,
          samples_per_chunk: &1.sample_count,
          sample_description_index: 1
        }
      )

  defp sample_sizes(%{sample_table: %{sample_sizes: sample_sizes}}),
    do: Enum.map(sample_sizes, &%{entry_size: &1})

  defp chunk_offsets(%{sample_table: %{chunk_offsets: chunk_offsets}}),
    do: Enum.map(chunk_offsets, &%{chunk_offset: &1})
end
