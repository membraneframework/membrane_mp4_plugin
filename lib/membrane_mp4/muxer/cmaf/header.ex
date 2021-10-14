defmodule Membrane.MP4.Muxer.CMAF.Header do
  @moduledoc false
  alias Membrane.MP4.{Box, Container, Track}

  @ftyp Box.FileType.assemble("iso5", ["iso6", "mp41"])

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

    movie_extends = Box.Movie.Extends.assemble(track)
    movie_box = Box.Movie.assemble(track, movie_extends)

    [@ftyp, movie_box]
    |> Enum.map(&Container.serialize!/1)
    |> Enum.join()
  end
end
