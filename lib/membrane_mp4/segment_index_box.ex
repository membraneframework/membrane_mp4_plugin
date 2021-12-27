defmodule Membrane.MP4.SegmentIndexBox do
  @moduledoc """
  A module containing a function for assembling a CMAF segment index box.

  The segment index box (`sidx` atom) contains information related to presentation
  time and byte-range locations of other boxes belonging to its segment.

  For more information about segment index box refer to
  [ISO/IEC 23000-19](https://www.iso.org/standard/79106.html).
  """
  alias Membrane.MP4.Container

  @spec assemble(%{
          id: non_neg_integer(),
          elapsed_time: non_neg_integer(),
          referenced_size: non_neg_integer(),
          timescale: non_neg_integer(),
          duration: non_neg_integer()
        }) :: Container.t()
  def assemble(config) do
    [
      sidx: %{
        children: [],
        fields: %{
          earliest_presentation_time: config.elapsed_time,
          first_offset: 0,
          flags: 0,
          reference_count: 1,
          reference_id: config.id,
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
end
