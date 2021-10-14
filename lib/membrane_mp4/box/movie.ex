defmodule Membrane.MP4.Box.Movie do
  @moduledoc """
  A module providing a function assembling an MPEG-4 movie box.

  The movie box (`moov`) is a top-level box that contains information about a presentation as a whole.
  It consists of:

    * exactly one movie header (`mvhd`)

      The movie header contains media-independent data, such as the
      number of tracks, volume, duration or timescale (presentation-wide).

    * one or more track box (`trak`)

    * zero or one movie extends box (`mvex`)

  For more information about movie box and its contents, refer to moduledocs in
  `Membrane.MP4.Box.Movie` or to [ISO/IEC 14496-12](https://www.iso.org/standard/74428.html).
  """
  alias Membrane.MP4.{Box, Container, Track}

  @movie_timescale 1000

  @spec assemble([%Track{}], Container.t()) :: Container.t()
  def assemble(tracks, extensions \\ []) do
    tracks = Enum.map(tracks, &Track.finalize(&1, @movie_timescale))

    header = movie_header(tracks)
    track_boxes = Enum.flat_map(tracks, &Box.Movie.Track.assemble/1)

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
end
