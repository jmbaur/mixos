from mixos import Machine
import logging
from argparse import ArgumentParser, REMAINDER

logging.basicConfig(level=logging.DEBUG)

parser = ArgumentParser()
parser.add_argument("ip", type=str, help="IP address of MixOS machine")
parser.add_argument("port", type=int, help="Port of MixOS testing backdoor")
parser.add_argument(
    "command",
    type=str,
    nargs=REMAINDER,
    help="Command to run on MixOS machine",
)
args = parser.parse_args()

with Machine(address=(args.ip, args.port), timeout=10) as machine:
    response = machine.run_command(args.command)
    print("exit_code: {}".format(response["exit_code"]))
    print("\nstdout:\n{}".format(bytes(response["stdout"]).decode().strip()))
    print("\nstderr:\n{}".format(bytes(response["stderr"]).decode().strip()))
