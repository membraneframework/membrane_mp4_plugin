defmodule Membrane.MP4.Muxer.CMAF.Header do
  @moduledoc false
  alias Membrane.MP4.{Container, FileTypeBox, MovieBox, Track}

  @ftyp FileTypeBox.assemble("iso5", ["iso6", "mp41"])

  @spec serialize([
          %Track{
            timescale: integer,
            width: :integer,
            height: :integer,
            content: struct,
            id: non_neg_integer()
          }
        ]) :: binary
  def serialize(tracks) do
    movie_extends = MovieBox.MovieExtendsBox.assemble(tracks)
    movie_box = MovieBox.assemble(tracks, movie_extends)

    [@ftyp, movie_box]
    |> Enum.map_join(&Container.serialize!/1)
  end
end
