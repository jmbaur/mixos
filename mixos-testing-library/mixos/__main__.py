from mixos import Machine
import logging
from argparse import ArgumentParser, REMAINDER


parser = ArgumentParser()
parser.add_argument(
    "-d", "--debug", action="store_true", help="Enable verbose logging", default=False
)
parser.add_argument(
    "-a",
    "--address",
    type=str,
    required=True,
    help="Address of the MixOS machine, of the form <ipv4>:<port>, [<ipv6>]:<port>, or vsock:<cid>:<port>",
)
parser.add_argument(
    "command",
    type=str,
    nargs=REMAINDER,
    help="Command to run on MixOS machine",
)
args = parser.parse_args()

logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

with Machine(args.address) as machine:
    response = machine.run_command(args.command)
    print("exit_code: {}".format(response["exit_code"]))
    print("\nstdout:\n{}".format(bytes(response["stdout"]).decode().strip()))
    print("\nstderr:\n{}".format(bytes(response["stderr"]).decode().strip()))
