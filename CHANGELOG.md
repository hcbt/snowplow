# Changelog

## [0.3.2](https://github.com/hcbt/snowplow/compare/v0.3.1...v0.3.2) (2026-08-01)


### Fixed

* **shell:** define the dev shell in flake.nix instead of nix/shells.nix ([#25](https://github.com/hcbt/snowplow/issues/25)) ([900f9eb](https://github.com/hcbt/snowplow/commit/900f9eb4c4fde1efa45ab05b1230c7425fdfd6cd))

## [0.3.1](https://github.com/hcbt/snowplow/compare/v0.3.0...v0.3.1) (2026-08-01)


### Fixed

* **deps:** bump nivis to v0.8.2 and coldstart to v0.3.1 ([#23](https://github.com/hcbt/snowplow/issues/23)) ([808b7dc](https://github.com/hcbt/snowplow/commit/808b7dc5f3cf2a94115ad01d643dea125b48e482))

## [0.3.0](https://github.com/hcbt/snowplow/compare/v0.2.3...v0.3.0) (2026-08-01)


### Added

* **chart:** let consumers add labels to the rendered Namespace ([#19](https://github.com/hcbt/snowplow/issues/19)) ([6784497](https://github.com/hcbt/snowplow/commit/6784497b8362796d6521c6b4ce5f4f28d7a64118))


### Fixed

* **checks:** stop chart-runner-supervision failing on a torn final iteration ([#21](https://github.com/hcbt/snowplow/issues/21)) ([53e3e76](https://github.com/hcbt/snowplow/commit/53e3e76def6499191038dd8d186477bf128c2386))

## [0.2.3](https://github.com/hcbt/snowplow/compare/v0.2.2...v0.2.3) (2026-07-30)


### Fixed

* **chart:** give a draining runner longer than a job to finish ([#17](https://github.com/hcbt/snowplow/issues/17)) ([26f7a23](https://github.com/hcbt/snowplow/commit/26f7a23e5e101df50c70946b1626afe5c15a00fb))


### Changed

* build the runner image through coldstart ([#13](https://github.com/hcbt/snowplow/issues/13)) ([0e51911](https://github.com/hcbt/snowplow/commit/0e5191185d92dd4b5787a807f413569718c6224f))

## [0.2.2](https://github.com/hcbt/snowplow/compare/v0.2.1...v0.2.2) (2026-07-30)


### Fixed

* **image:** provide /usr/bin/env and the runner's internal node external ([#10](https://github.com/hcbt/snowplow/issues/10)) ([0175657](https://github.com/hcbt/snowplow/commit/0175657d5b8f2308362a164fcf774c7a5fc8fa6a))

## [0.2.1](https://github.com/hcbt/snowplow/compare/v0.2.0...v0.2.1) (2026-07-30)


### Fixed

* **chart:** supervise the listener in-container instead of exiting per job ([#7](https://github.com/hcbt/snowplow/issues/7)) ([e02c272](https://github.com/hcbt/snowplow/commit/e02c272fcc7d23b3825249ae4f7825dac61701b7))

## [0.2.0](https://github.com/hcbt/snowplow/compare/v0.1.0...v0.2.0) (2026-07-29)


### Added

* adopt nivis for the shared scaffolding ([#4](https://github.com/hcbt/snowplow/issues/4)) ([937681e](https://github.com/hcbt/snowplow/commit/937681e2baede58b848a75da07156deeacf913e8))
