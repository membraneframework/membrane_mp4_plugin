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

    moof_config = Map.take(config, [:sequence_number, :elapsed_time, :timescale, :duration])
    moof = Box.MovieFragment.assemble(moof_config) |> Container.serialize!()

    mdat = Box.MediaData.assemble(config.samples_data) |> Container.serialize!()

    sidx_config =
      config
      |> Map.take([:elapsed_time, :timescale, :duration])
      |> Map.put(:referenced_size, byte_size(moof) + byte_size(mdat))

    sidx = Box.SegmentIndex.assemble(sidx_config) |> Container.serialize!()

    styp <> sidx <> moof <> mdat
  end
end
