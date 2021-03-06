defmodule Membrane.MP4.CMAF.Muxer.Segment do
  @moduledoc false
  alias Membrane.MP4.Container

  @mdat_data_offset 8

  @trun_flags %{data_offset: 1, sample_duration: 0x100, sample_size: 0x200, sample_flags: 0x400}

  @spec serialize(%{
          sequence_number: integer,
          elapsed_time: integer,
          timescale: integer,
          duration: integer,
          samples_table: [%{sample_size: integer, sample_flags: integer}],
          samples_data: binary
        }) :: binary
  def serialize(config) do
    sample_count = length(config.samples_table)

    config =
      config
      |> Map.merge(%{
        sample_count: sample_count,
        data_offset: 0,
        referenced_size: nil
      })

    mdat = Container.serialize!(mdat: %{content: config.samples_data})
    moof = Container.serialize!(moof(config))
    config = %{config | data_offset: byte_size(moof) + @mdat_data_offset}
    moof = Container.serialize!(moof(config))
    config = %{config | referenced_size: byte_size(moof) + byte_size(mdat)}
    header = Container.serialize!(header(config))
    header <> moof <> mdat
  end

  defp header(config) do
    [
      styp: %{
        children: [],
        fields: %{
          compatible_brands: ["msdh", "msix"],
          major_brand: "msdh",
          major_brand_version: 0
        }
      },
      sidx: %{
        children: [],
        fields: %{
          earliest_presentation_time: config.elapsed_time,
          first_offset: 0,
          flags: 0,
          reference_count: 1,
          reference_id: 1,
          reference_type: <<0::size(1)>>,
          referenced_size: config.referenced_size,
          sap_delta_time: 0,
          sap_type: 0,
          starts_with_sap: <<1::size(1)>>,
          subsegment_duration: config.duration,
          timescale: config.timescale,
          version: 1
        }
      }
    ]
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
                  track_id: 1,
                  version: 0
                }
              },
              tfdt: %{
                children: [],
                fields: %{
                  base_media_decode_time: config.elapsed_time,
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
                      @trun_flags.sample_size + @trun_flags.sample_flags,
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
