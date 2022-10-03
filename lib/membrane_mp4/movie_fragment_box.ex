defmodule Membrane.MP4.MovieFragmentBox do
  @moduledoc """
  A module containing a function for assembling an MPEG-4 movie fragment box.

  The movie fragment box (`moof` atom) is a top-level box and consists of:

    * exactly one movie fragment header (`mfhd` atom)

      The movie fragment header contains a sequence number that is
      increased for every subsequent movie fragment in order in which
      they occur.

    * zero or more track fragment box (`traf` atom)

      The track fragment box provides information related to a track
      fragment's presentation time, duration and physical location of
      its samples in the media data box.

  This box is required by Common Media Application Format.

  For more information about movie fragment box and its contents refer to
  [ISO/IEC 14496-12](https://www.iso.org/standard/74428.html) or to
  [ISO/IEC 23000-19](https://www.iso.org/standard/79106.html).
  """
  alias Membrane.MP4.Container

  @trun_flags %{
    data_offset: 1,
    sample_duration: 0x100,
    sample_size: 0x200,
    sample_flags: 0x400,
    sample_composition_time_offsets_present: 0x800
  }
  @mdat_data_offset 8

  @spec assemble(%{
          sequence_number: integer,
          elapsed_time: integer,
          timescale: integer,
          duration: integer,
          samples_table: [%{sample_size: integer, sample_flags: integer}]
        }) :: Container.t()
  def assemble(config) do
    config =
      config
      |> Map.merge(%{
        sample_count: length(config.samples_table),
        data_offset: 0
      })

    moof_size = moof(config) |> Container.serialize!() |> byte_size()

    config = %{config | data_offset: moof_size + @mdat_data_offset}

    moof(config)
  end

  defp moof(config) do
    [
      moof: %{
        children: [
          mfhd: %{
            children: [],
            fields: %{flags: 0, sequence_number: config.sequence_number, version: 0}
          },
          traf: %{
            children: [
              tfhd: %{
                children: [],
                fields: %{
                  default_sample_duration: 0,
                  default_sample_flags: 0,
                  default_sample_size: 0,
                  flags: 0b100000000000111000,
                  track_id: config.id,
                  version: 0
                }
              },
              tfdt: %{
                children: [],
                fields: %{
                  base_media_decode_time: config.base_timestamp,
                  flags: 0,
                  version: 1
                }
              },
              trun: %{
                children: [],
                fields: %{
                  data_offset: config.data_offset,
                  flags:
                    @trun_flags.data_offset + @trun_flags.sample_duration +
                      @trun_flags.sample_size + @trun_flags.sample_flags +
                      @trun_flags.sample_composition_time_offsets_present,
                  sample_count: config.sample_count,
                  samples: config.samples_table,
                  version: 0
                }
              }
            ],
            fields: %{}
          }
        ],
        fields: %{}
      }
    ]
  end
end
