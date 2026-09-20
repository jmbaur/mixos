# Use version defined in build.zig.zon
let
  lines = builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile ./build.zig.zon));
  matches = builtins.filter (match: match != null) (
    map (builtins.match "[[:space:]]*\\.version = \"([^\"]+)\",") lines
  );
in
if matches == [ ] then
  throw "no `.version` field found in build.zig.zon"
else
  builtins.head (builtins.head matches)
