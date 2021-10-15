defmodule Membrane.MP4.Muxer.CMAF.Segment do
  @moduledoc false
  alias Membrane.MP4.{Box, Container}

  @spec serialize(%{
          sequence_number: integer,
          elapsed_time: integer,
          timescale: integer,
          duration: integer,
          samples_table: [%{sample_size: integer, sample_flags: integer}],
          samples_data: binary
        }) :: binary
  def serialize(config) do
    styp = Box.SegmentType.assemble("msdh", ["msdh", "msix"]) |> Container.serialize!()
    moof = Box.MovieFragment.assemble(config) |> Container.serialize!()
    mdat = Box.MediaData.assemble(config.samples_data) |> Container.serialize!()

    sidx =
      config
      |> Map.take([:elapsed_time, :timescale, :duration])
      |> Map.put(:referenced_size, byte_size(moof) + byte_size(mdat))
      |> Box.SegmentIndex.assemble()
      |> Container.serialize!()

    styp <> sidx <> moof <> mdat
  end
end
