defmodule Membrane.MP4.SegmentTypeBox do
  @moduledoc """
  A module containing a function for assembling a CMAF segment type box.

  The segment type box (`styp` atom) is a top-level box that contains specifications
  and compatibility information that media players can use to correctly interpret
  a CMAF segment.

  For more information about the segment type box, refer to
  [ISO/IEC 23000-19](https://www.iso.org/standard/79106.html).
  """
  alias Membrane.MP4.Container

  @spec assemble(String.t(), [String.t()], integer) :: Container.t()
  def assemble(major_brand, compatible_brands, major_brand_version \\ 0) do
    [
      styp: %{
        children: [],
        fields: %{
          major_brand: major_brand,
          major_brand_version: major_brand_version,
          compatible_brands: compatible_brands
        }
      }
    ]
  end
end
