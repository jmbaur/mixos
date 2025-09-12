from schema import Schema
from typing import TypedDict
import json
import logging
import socket

logger = logging.getLogger(__name__)


run_command_schema = Schema(
    {
        "exit_code": int,
        "stdout": [int],
        "stderr": [int],
    }
)


class RunCommandResult(TypedDict):
    exit_code: int
    stdout: list[int]
    stderr: list[int]


class Machine:
    def __init__(self, *args, **kwargs):
        """
        Creates a new MixOS Machine

        All args and kwargs are passed to `socket.create_connection()`.
        """
        self.create_connection_args = args
        self.create_connection_kwargs = kwargs
        self.sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, type, value, traceback):
        _ = type
        _ = value
        _ = traceback

        if self.sock is not None:
            self.sock.__exit__()

    def connect(self):
        retries = 0
        while True:
            try:
                logger.debug("attempting connection")
                self.sock = socket.create_connection(
                    *self.create_connection_args, **self.create_connection_kwargs
                )
                return
            except OSError as e:
                logger.info("connection failed, retrying")
                retries += 1
                if retries > 10:
                    raise e

    def recv_message(self):
        assert self.sock is not None

        buf = bytearray()

        while True:
            data = self.sock.recv(1 << 16)
            if not data:
                raise Exception("socket closed")

            buf_len = len(buf)
            buf.extend(data)

            null_index = data.find(0)
            if null_index >= 0:
                raw_response = bytes(buf[: buf_len + null_index])
                break

        logger.debug("message from machine: {}".format(raw_response))
        response = json.loads(raw_response)
        if "error" in response:
            raise Exception(response["error"])

        return response["result"]

    def run_command(self, command: list[str]) -> RunCommandResult:
        assert self.sock is not None
        if len(command) == 0:
            raise ValueError("empty command")
        self.sock.send(json.dumps({"run_command": {"command": command}}).encode())
        self.sock.send("\0".encode())
        response = self.recv_message()
        valid = run_command_schema.validate(response["run_command"])
        return RunCommandResult(valid)


if __name__ == "__main__":
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
