{ config, lib, ... }:
let
  inherit (config.mixos.nodes) machine broken;

  pkgs = machine.nixpkgs.pkgs;

  mixos = machine.mixos.package;

  binutils = pkgs.buildPackages.binutils;
in
{
  name = "mixos-debug-info";

  mixos.nodes.machine = { };

  mixos.nodes.broken = {
    system.build.manifest = lib.mkForce (
      pkgs.runCommand "mixos-manifest-empty-init.json" { } ''
        ${lib.getExe pkgs.jq} '.init = []' ${machine.system.build.manifest} > "$out"
      ''
    );
  };

  testScript = ''
    import datetime
    import hashlib
    import os
    import re
    import subprocess

    MIXOS = "${mixos}/bin/mixos"
    DEBUG = "${mixos.debug}"

    ADDR2LINE = "${binutils}/bin/addr2line"
    READELF = "${binutils}/bin/readelf"

    CRASH_MESSAGE = "init could not transition to stage 2"
    CRASH_SOURCE = "src/init.zig"

    PAGE_SIZE = 4096


    def host(*argv):
        """Run a command where the test driver runs, not on the machine."""
        return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


    def sections(path):
        return host(READELF, "--section-headers", "--wide", path)


    def build_id(path):
        found = re.search(r"Build ID: ([0-9a-f]{40})", host(READELF, "--notes", path))
        assert found, f"{path} carries no GNU build ID"
        return found.group(1)


    BUILD_ID = build_id(MIXOS)
    DEBUG_DIR = f"{DEBUG}/lib/debug/.build-id/{BUILD_ID[:2]}"
    DEBUG_FILE = f"{DEBUG_DIR}/{BUILD_ID[2:]}.debug"


    def functions(path):
        """Every function in the symbol table, by name: [(address, size)]."""
        table = {}
        for line in host(READELF, "--syms", "--wide", path).splitlines():
            fields = line.split()
            if len(fields) == 8 and fields[3] == "FUNC":
                table.setdefault(fields[7], []).append(
                    (int(fields[1], 16), int(fields[2], 0))
                )
        return table


    def load_base(frames):
        """Where the machine loaded the binary, from the frames it printed."""
        table = functions(MIXOS)
        candidates = None

        for address, name in frames:
            runtime = int(address, 16)
            fits = set()
            for start, size in table.get(name, []):
                lowest = runtime - start - max(size, 1) + 1
                highest = runtime - start
                page = -(-lowest // PAGE_SIZE) * PAGE_SIZE
                while page <= highest:
                    fits.add(page)
                    page += PAGE_SIZE
            if fits:
                candidates = fits if candidates is None else candidates & fits

        assert candidates and len(candidates) == 1, (
            f"the frames do not pin down one load base: {candidates}"
        )
        return candidates.pop()


    def resolve(address):
        """What the debug output makes of an address in the shipped binary."""
        return host(
            ADDR2LINE,
            "--exe=" + DEBUG_FILE,
            "--functions",
            "--inlines",
            "--pretty-print",
            address,
        ).strip()


    with subtest("the machines run the binary the debug output describes"):
        assert "${broken.mixos.package}" == "${mixos}", (
            "the two machines were built against different mixos packages"
        )

        with open(MIXOS, "rb") as binary:
            in_store = hashlib.file_digest(binary, "sha256").hexdigest()

        on_machine = machine.succeed("sha256sum /bin/mixos").split()[0]

        assert on_machine == in_store, (
            f"the machine runs {on_machine}, but this test is reading {in_store}"
        )


    with subtest("the binary in the image carries no debug info"):
        image_sections = sections(MIXOS)

        assert ".debug_info" not in image_sections, (
            "the shipped binary still carries DWARF: the initramfs is unpacking "
            "debug info into RAM at every boot that nothing on the machine can use"
        )

        # The hook strips debug info and nothing else, so the symbol table
        # survives. It is why a panic on the machine can still name functions.
        assert ".symtab" in image_sections, "the shipped binary has no symbol table"


    with subtest("the debug output holds it, keyed by build ID"):
        assert os.path.exists(DEBUG_FILE), f"no debug info at {DEBUG_FILE}"

        debug_sections = sections(DEBUG_FILE)
        for section in (".debug_info", ".debug_line"):
            assert section in debug_sections, f"{DEBUG_FILE} has no {section}"

        # The other half of the build ID entry, and what gets a debugger from
        # the debug info back to the binary it describes.
        executable = os.path.realpath(f"{DEBUG_DIR}/{BUILD_ID[2:]}.executable")
        assert executable == os.path.realpath(MIXOS), (
            f"the build ID points at {executable}, not at {MIXOS}"
        )


    with subtest("a PID 1 panic reaches the console, and cannot place itself"):
        broken.start()

        broken.wait_for_console_text(
            f"panic: {CRASH_MESSAGE}", timeout=datetime.timedelta(seconds=120)
        )

        # Get output of panic onwards
        console = re.sub(r"\x1b\[[0-9;]*m", "", broken.get_console_log())
        trace = console[console.index(f"panic: {CRASH_MESSAGE}"):]

        # Zig looks for a separate debug file under /usr/lib/debug, next to the
        # binary, or in a debuginfod cache. We don't have any of that, so the
        # trace names functions out of .symtab and can say nothing about where
        # in the source they are.
        assert CRASH_SOURCE not in trace, (
            f"the machine placed its own crash without the debug output:\n{trace}"
        )

        frames = re.findall(r"0x([0-9a-f]+) in (\S+)", trace)
        assert frames, f"no addresses in:\n{trace}"


    with subtest("the debug output places it"):
        base = load_base(frames)
        assert base != 0, "the machine ran mixos at its link address: no ASLR"

        located = [resolve(hex(int(address, 16) - base)) for address, _ in frames]

        crash_function = frames[0][1]

        assert crash_function in located[0], (
            f"the innermost frame is {crash_function} on the machine, "
            f"but {located[0]} here"
        )
        assert CRASH_SOURCE in located[0], (
            f"{crash_function} was not placed in {CRASH_SOURCE}: {located[0]}"
        )

        # The whole trace, not just the one frame we went looking for.
        assert len(located) > 1, f"only one frame came back:\n{located[0]}"

        unplaced = [frame for frame in located if "??" in frame]
        assert not unplaced, (
            "frames the debug output could not place:\n" + "\n".join(unplaced)
        )


    with subtest("the debug output gives the crash a line number"):
        crash_line = re.search(re.escape(CRASH_SOURCE) + r":(\d+)", located[0])

        assert crash_line, (
            f"the crash frame came back without a line number: {located[0]}"
        )


    with subtest("the placed traceback is left in the test's output"):
        report = broken.out_dir / "traceback.md"

        with open(report, "w") as out:
            print("# mixos stage 1 panic", file=out)
            print("#", file=out)
            print(f"# message   {CRASH_MESSAGE}", file=out)
            print(f"# binary    {MIXOS}", file=out)
            print(f"# build ID  {BUILD_ID}", file=out)
            print(f"# debug     {DEBUG_FILE}", file=out)
            print(f"# loaded at {base:#x}", file=out)

            print("\n## as the machine printed it on the console\n", file=out)
            print(trace.strip(), file=out)

            print("\n## placed with the debug output\n", file=out)
            for (address, _), placed_frame in zip(frames, located):
                head, *inlined = placed_frame.splitlines()
                indent = " " * (len(address) + 4)

                print(f"0x{address}  {head}", file=out)
                for inline in inlined:
                    print(indent + inline.strip(), file=out)

        written = report.read_text()
        assert CRASH_SOURCE in written, f"nothing was placed in:\n{written}"
  '';
}
