defmodule Membrane.MP4.CMAF.Muxer.Header do
  @moduledoc false
  alias Membrane.MP4.{CommonBox, Container, Track}

  @spec serialize(%{
          timescale: integer,
          width: :integer,
          height: :integer,
          content: struct
        }) :: binary
  def serialize(config) do
    track = config |> Map.put(:id, 1) |> Track.new() |> Track.finalize(1)

    ftyp = CommonBox.file_type_box()
    mvex = movie_extends()
    moov = CommonBox.movie_box([track], 1, [0], mvex)

    (ftyp ++ moov) |> Container.serialize!()
  end

  defp movie_extends() do
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
