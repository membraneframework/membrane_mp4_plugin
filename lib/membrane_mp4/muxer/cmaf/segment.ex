defmodule Membrane.MP4.Muxer.CMAF.Segment do
  @moduledoc false
  alias Membrane.MP4.{Container, MediaDataBox, MovieFragmentBox, SegmentIndexBox, SegmentTypeBox}

  @spec serialize([
          %{
            sequence_number: integer,
            base_timestamp: integer,
            timescale: integer,
            duration: integer,
            samples_table: [%{sample_size: integer, sample_flags: integer}],
            samples_data: binary
          }
        ]) :: binary
  def serialize(configs) do
    styp = SegmentTypeBox.assemble("msdh", ["msdh", "msix"]) |> Container.serialize!()

    tracks_data =
      Enum.flat_map(configs, fn config ->
        # fix for dialyzer
        moof_config = Map.delete(config, :samples_data)
        moof = MovieFragmentBox.assemble(moof_config) |> Container.serialize!()

        mdat = MediaDataBox.assemble(config.samples_data) |> Container.serialize!()

        sidx_config =
          config
          |> Map.take([:id, :base_timestamp, :timescale, :duration])
          |> Map.put(:referenced_size, byte_size(moof) + byte_size(mdat))

        sidx = SegmentIndexBox.assemble(sidx_config) |> Container.serialize!()
        [sidx, moof, mdat]
      end)

    [styp | tracks_data] |> Enum.join()
  end
end
