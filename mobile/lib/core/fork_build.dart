/// Identity and version label for Rock's standalone phone build.
const bool kRockForkBuild = true;
const String kRockForkName = 'Rock OpenHarness';
const String kRockBuildSha = String.fromEnvironment('ROCK_BUILD_SHA');

String rockForkVersion(String version, {String sha = kRockBuildSha}) {
  if (!kRockForkBuild || version.contains('-rock')) return version;
  return sha.isEmpty ? '$version-rock' : '$version-rock.$sha';
}
