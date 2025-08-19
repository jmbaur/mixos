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


class SuccessResponse(BaseModel):
    term: Exited | Signal | Stopped | Unknown = Field(union_mode="smart")
    stdout: str
    stderr: str


class Success(BaseModel):
    success: SuccessResponse


class Failure(BaseModel):
    failure: str


class ServerMessage(BaseModel):
    response: Success | Failure = Field(union_mode="smart")


class Machine:
    def __init__(self, address: tuple[str | None, int]):
        self.address = address
        self.sock = None

    def __enter__(self):
        self.connect(self.address)
        return self

    def __exit__(self, type, value, traceback):
        _ = type
        _ = value
        _ = traceback

        if self.sock is not None:
            self.sock.__exit__()

    def connect(self, address: tuple[str | None, int]):
        self.sock = socket.create_connection(address)

    def run_command(self, command: list[str]) -> Success | Failure:
        assert self.sock is not None
        self.sock.send(json.dumps({"command": command}).encode())
        self.sock.send("\0".encode())
        raw_response = self.sock.recv(1 << 16)
        response = json.loads(raw_response)
        return ServerMessage.model_validate(response).response


if __name__ == "__main__":
    import sys

    with Machine((sys.argv[1], int(sys.argv[2]))) as machine:
        response = machine.run_command(sys.argv[3:])
        if isinstance(response, Success):
            print("term:", response.success.term)
            print("stdout:\n", response.success.stdout.strip())
            print("stderr:\n", response.success.stderr.strip())
        else:
            print("failure:", response.failure)
