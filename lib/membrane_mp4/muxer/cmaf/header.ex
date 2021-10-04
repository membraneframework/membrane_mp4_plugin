defmodule Membrane.MP4.Muxer.CMAF.Header do
  @moduledoc false
  alias Membrane.MP4.Container
  alias Membrane.MP4.Muxer.{MovieBox, Track}

  @ftyp [
          ftyp: %{
            children: [],
            fields: %{
              compatible_brands: ["iso6", "mp41"],
              major_brand: "iso5",
              major_brand_version: 512
            }
          }
        ]
        |> Container.serialize!()

  @mvex [
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
      |> Track.new()

    movie_box = MovieBox.serialize([track], @mvex)

    @ftyp <> movie_box
  end
end
