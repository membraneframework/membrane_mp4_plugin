defmodule Membrane.MP4.CMAF.Muxer.Header do
  @moduledoc false
  alias Membrane.MP4.Container
  alias Membrane.MP4.Common.{Box, Track}

  @spec serialize(%{
          timescale: integer,
          width: :integer,
          height: :integer,
          content: struct
        }) :: binary
  def serialize(config) do
    ftyp = Box.file_type_box()

    track = config |> Map.merge(%{id: 1, kind: :cmaf}) |> Track.new()
    moov = Box.movie_box(track)

    (ftyp ++ moov) |> Container.serialize!()
  end
end
