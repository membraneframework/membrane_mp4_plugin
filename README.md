# MPEG-4 container plugin for Membrane Framework

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_mp4_plugin.svg)](https://hex.pm/packages/membrane_mp4_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_mp4_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_mp4_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_mp4_plugin)

This plugin provides utilities for MP4 container parsing and serialization and elements for muxing the stream to [CMAF](https://www.wowza.com/blog/what-is-cmaf).

## Updating tests

In case `out_*` reference files in `test/fixtures` change, `out_playlist.m3u8` and its dependent playlists should be updated and checked if they are still playable. The current files have been checked with ffplay (FFmpeg) and Safari.

## Copyright and License

Copyright 2019, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_mp4_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_mp4_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
