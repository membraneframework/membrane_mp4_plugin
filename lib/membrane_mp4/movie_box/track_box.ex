defmodule Membrane.MP4.MovieBox.TrackBox do
  @moduledoc """
  A module containing a set of utilities for assembling an MPEG-4 track box.

  The track box (`trak` atom) describes a single track of a presentation. This description includes
  information like its timescale, duration, volume, media-specific data (media handlers, sample
  descriptions) as well as a sample table, which allows media players to find and interpret
  track's data in the media data box.

  For more information about the track box, refer to [ISO/IEC 14496-12](https://www.iso.org/standard/74428.html).
  """
  alias Membrane.MP4.{Container, MovieBox.SampleTableBox, Track}

  defguardp is_audio(track) when {track.height, track.width} == {0, 0}

  @spec assemble(Track.t()) :: Container.t()
  def assemble(track) do
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
                            dinf ++ SampleTableBox.assemble(track.sample_table),
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

  @spec unpack(%{children: Container.t(), fields: map}) :: Track.t()
  def unpack(%{children: boxes}) do
    header = boxes[:tkhd].fields
    media = boxes[:mdia].children

    sample_table =
      SampleTableBox.unpack(media[:minf].children[:stbl], media[:mdhd].fields.timescale)

    {height, 0} = header.height
    {width, 0} = header.width

    %Track{
      id: header.track_id,
      content: sample_table.sample_description.content,
      height: height,
      width: width,
      timescale: media[:mdhd].fields.timescale,
      sample_table: sample_table,
      duration: nil,
      movie_duration: nil
    }
  end
end
