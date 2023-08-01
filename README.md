# MPEG-4 container plugin for Membrane Framework

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_mp4_plugin.svg)](https://hex.pm/packages/membrane_mp4_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_mp4_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_mp4_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_mp4_plugin)

This plugin provides utilities for MP4 container parsing and serialization along with elements for muxing the stream to MP4 or [CMAF](https://www.wowza.com/blog/what-is-cmaf).

## Installation
The package can be installed by adding `membrane_mp4_plugin` to your list of dependencies in `mix.exs`:

```elixir
defp deps do
  [
    {:membrane_mp4_plugin, "~> 0.26.1"}
  ]
end
```

## Usage
### `Membrane.MP4.Muxer.ISOM`
ISOM muxer requires a sink that can handle `Membrane.File.SeekSinkEvent`, e.g. `Membrane.File.Sink`.
For an example of muxing streams to a regular MP4 file, refer to [`examples/muxer_isom.exs`](examples/muxer_isom.exs).

To run the example, you can use the following command:
```bash
elixir examples/muxer_isom.exs
```

You can expect an `example.mp4` file containing muxed audio and video to be saved in your working directory.

### `Membrane.MP4.Muxer.CMAF`
For an example of muxing streams into CMAF format, refer to [`examples/muxer_cmaf.exs`](examples/muxer_cmaf.exs). CMAF requires a special sink, regular `Membrane.File.Sink` will not work correctly. Currently, Membrane Framework has only one sink capable of saving a CMAF stream - `Membrane.HTTPAdaptiveStream.Sink`.

To run the example, use the following command:
```bash
elixir examples/muxer_cmaf.exs
```

You can expect `hls_output` folder to appear and be filled with CMAF header and segments, as well as an HLS playlist.
To play the stream, you need to serve the contents of the output folder with an HTTP Server. If you are looking for
something quick and simple, you can use Python's [`http.server`](https://docs.python.org/3/library/http.server.html):
```bash
python3 -m http.server -d hls_output 8000
```
and run the following command to play the stream:
```bash
ffplay http://localhost:8000/index.m3u8
```

## Updating tests

In case `out_*` reference files in `test/fixtures/cmaf` change, `out_playlist.m3u8` and its dependent playlists should be updated and checked if they are still playable.
The current files have been checked with ffplay (FFmpeg) and Safari.

## Copyright and License

Copyright 2019, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_mp4_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_mp4_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
