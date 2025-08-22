import json
import socket
from pydantic import BaseModel, Field


class Exited(BaseModel):
    Exited: int


class Signal(BaseModel):
    Signal: int


class Stopped(BaseModel):
    Stopped: int


class Unknown(BaseModel):
    Unknown: int


class ServerRunResultMessage(BaseModel):
    term: Exited | Signal | Stopped | Unknown = Field(union_mode="smart")
    stdout: str
    stderr: str


class ServerRunCommandMessage(BaseModel):
    run_command: ServerRunResultMessage


class ServerMessage(BaseModel):
    result: ServerRunCommandMessage


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
        self.sock = socket.create_connection(
            *self.create_connection_args, **self.create_connection_kwargs
        )

    def recv_message(self, model):
        assert self.sock is not None
        raw_response = self.sock.recv(1 << 16)
        response = json.loads(raw_response)
        if "error" in response:
            raise Exception(response["error"])

        return model.model_validate(response)

    def run_command(self, command: list[str]):
        assert self.sock is not None
        self.sock.send(json.dumps({"run_command": {"command": command}}).encode())
        self.sock.send("\0".encode())
        return self.recv_message(ServerMessage)


if __name__ == "__main__":
    from argparse import ArgumentParser, REMAINDER

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
        response = machine.run_command(args.command).result.run_command
        print("term: {}".format(response.term))
        print("\nstdout:\n{}".format(response.stdout.strip()))
        print("\nstderr:\n{}".format(response.stderr.strip()))
