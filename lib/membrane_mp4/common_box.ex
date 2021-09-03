defmodule Membrane.MP4.CommonBox do
  @moduledoc false
  alias Membrane.MP4.Payload.{AAC, AVC1}

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

  @spec file_type :: keyword()
  def file_type(), do: @ftyp

  @spec media_data([%Membrane.Buffer{}]) :: keyword()
  def media_data(buffers) do
    [
      mdat: %{
        content: buffers |> Enum.map(& &1.payload) |> Enum.join()
      }
    ]
  end

  @spec movie_header(%{
          common_duration: integer,
          common_timescale: integer,
          next_track_id: integer
        }) ::
          keyword()
  def movie_header(config) do
    [
      mvhd: %{
        children: [],
        fields: %{
          creation_time: 0,
          duration: config.common_duration,
          flags: 0,
          matrix_value_A: {1, 0},
          matrix_value_B: {0, 0},
          matrix_value_C: {0, 0},
          matrix_value_D: {1, 0},
          matrix_value_U: {0, 0},
          matrix_value_V: {0, 0},
          matrix_value_W: {1, 0},
          matrix_value_X: {0, 0},
          matrix_value_Y: {0, 0},
          modification_time: 0,
          next_track_id: config.next_track_id,
          quicktime_current_time: 0,
          quicktime_poster_time: 0,
          quicktime_preview_duration: 0,
          quicktime_preview_time: 0,
          quicktime_selection_duration: 0,
          quicktime_selection_time: 0,
          rate: {1, 0},
          timescale: config.common_timescale,
          version: 0,
          volume: {1, 0}
        }
      }
    ]
  end

  @spec track_header(%{
          common_duration: integer,
          height: integer,
          width: integer,
          content: struct,
          track_id: integer
        }) ::
          keyword()
  def track_header(config) do
    [
      tkhd: %{
        children: [],
        fields: %{
          alternate_group: 0,
          creation_time: 0,
          duration: config.common_duration,
          flags: 3,
          height: {config.height, 0},
          layer: 0,
          matrix_value_A: {1, 0},
          matrix_value_B: {0, 0},
          matrix_value_C: {0, 0},
          matrix_value_D: {1, 0},
          matrix_value_U: {0, 0},
          matrix_value_V: {0, 0},
          matrix_value_W: {1, 0},
          matrix_value_X: {0, 0},
          matrix_value_Y: {0, 0},
          modification_time: 0,
          track_id: config.track_id,
          version: 0,
          volume:
            case config.content do
              %AVC1{} -> {0, 0}
              %AAC{} -> {1, 0}
            end,
          width: {config.width, 0}
        }
      }
    ]
  end

  @spec media_handler_header(%{duration: integer, timescale: integer}) :: keyword()
  def media_handler_header(config) do
    [
      mdhd: %{
        children: [],
        fields: %{
          creation_time: 0,
          duration: config.duration,
          flags: 0,
          language: 21956,
          modification_time: 0,
          timescale: config.timescale,
          version: 0
        }
      }
    ]
  end

  def sample_description(%{content: %AVC1{} = avc1} = config) do
    [
      avc1: %{
        children: [
          avcC: %{
            content: avc1.avcc
          },
          pasp: %{
            children: [],
            fields: %{h_spacing: 1, v_spacing: 1}
          }
        ],
        fields: %{
          compressor_name: <<0::size(32)-unit(8)>>,
          depth: 24,
          flags: 0,
          frame_count: 1,
          height: config.height,
          horizresolution: {0, 0},
          num_of_entries: 1,
          version: 0,
          vertresolution: {0, 0},
          width: config.width
        }
      }
    ]
  end

  def sample_description(%{content: %AAC{} = aac}) do
    [
      mp4a: %{
        children: %{
          esds: %{
            fields: %{
              elementary_stream_descriptor: aac.esds,
              flags: 0,
              version: 0
            }
          }
        },
        fields: %{
          channel_count: aac.channels,
          compression_id: 0,
          data_reference_index: 1,
          encoding_revision: 0,
          encoding_vendor: 0,
          encoding_version: 0,
          packet_size: 0,
          sample_size: 16,
          sample_rate: {aac.sample_rate, 0}
        }
      }
    ]
  end

  def handler(%{content: %AVC1{}}) do
    [
      hdlr: %{
        children: [],
        fields: %{
          flags: 0,
          handler_type: "vide",
          name: "VideoHandler",
          version: 0
        }
      }
    ]
  end

  def handler(%{content: %AAC{}}) do
    [
      hdlr: %{
        children: [],
        fields: %{
          flags: 0,
          handler_type: "soun",
          name: "SoundHandler",
          version: 0
        }
      }
    ]
  end

  def media_header(%{content: %AVC1{}}) do
    [
      vmhd: %{
        children: [],
        fields: %{
          flags: 1,
          graphics_mode: 0,
          opcolor: 0,
          version: 0
        }
      }
    ]
  end

  def media_header(%{content: %AAC{}}) do
    [
      smhd: %{
        children: [],
        fields: %{
          balance: {0, 0},
          flags: 0,
          version: 0
        }
      }
    ]
  end
end
