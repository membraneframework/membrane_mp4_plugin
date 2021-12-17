defmodule Membrane.MP4.Muxer.CMAF.Header do
  @moduledoc false
  alias Membrane.MP4.{Container, FileTypeBox, MovieBox, Track}

  @ftyp FileTypeBox.assemble("iso5", ["iso6", "mp41"])

  @spec serialize(%{
          timescale: integer,
          width: :integer,
          height: :integer,
          content: struct
        }) :: binary
  def serialize(config) do
    track =
      config
      |> Map.take([:timescale, :width, :height, :content])
      |> Map.put(:id, 1)
      |> Track.new()
      |> List.wrap()

    movie_extends = MovieBox.MovieExtendsBox.assemble(track)
    movie_box = MovieBox.assemble(track, movie_extends)

    [@ftyp, movie_box]
    |> Enum.map_join(&Container.serialize!/1)
  end
end
